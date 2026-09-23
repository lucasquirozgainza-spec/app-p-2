import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/auth_service.dart';
import '../services/cloud.dart';
import '../services/config_sync.dart';
import '../services/turnos.dart';
import '../widgets/common.dart';
import '../services/pdf_export.dart';
import '../services/panel_horas.dart';
import '../theme.dart';
import '../widgets/toast.dart';
import 'reporte_personal_screen.dart';
import 'advertencias_screen.dart';

class GuardiasScreen extends StatefulWidget {
  const GuardiasScreen({super.key});
  @override
  State<GuardiasScreen> createState() => _GuardiasScreenState();
}

class _GuardiasScreenState extends State<GuardiasScreen> {
  List<Map<String, dynamic>> _activosLocal = [];
  List<Map<String, dynamic>> _presencia = []; // en linea desde la nube (todos los celulares)
  List<Map<String, dynamic>> _personal = [];
  Map<String, List<PanelPuesto>> _panel = {}; // edificio -> puestos (nube)
  bool _cargandoNube = false;
  DateTime _mes = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final activos = await db.query('ingreso_turno',
        where: 'edificio=? AND activo=1', whereArgs: [ed], orderBy: 'id DESC');
    final personal = await db.query('usuarios',
        where: "rol IN ('guardia','supervisor','conserje','limpieza','franquero') AND activo=1 "
            "AND (edificio=? OR edificio IS NULL OR edificio='')",
        whereArgs: [ed],
        orderBy: 'nombre');
    // Lo local se muestra YA; la nube llega después (sin señal no deja la
    // pantalla vacía esperando).
    if (!mounted) return;
    setState(() {
      _activosLocal = activos;
      _personal = personal;
      _cargandoNube = !AppState.instance.soloLocal;
    });
    if (AppState.instance.soloLocal) return;
    Cloud.heartbeat();
    final res = await Future.wait([Cloud.presencia(), Cloud.eventosTurnoMes(mes: _mes)]);
    final pres = res[0];
    final panel = _calcularPanel(res[1]);
    if (!mounted) return;
    setState(() {
      _presencia = pres;
      _panel = panel;
      _cargandoNube = false;
    });
  }

  /// Cambia el mes del panel de horas (solo recarga las horas).
  Future<void> _cambiarMes(int delta) async {
    setState(() {
      _mes = DateTime(_mes.year, _mes.month + delta);
      _cargandoNube = true;
      _panel = {};
    });
    final ev = await Cloud.eventosTurnoMes(mes: _mes);
    if (!mounted) return;
    setState(() {
      _panel = _calcularPanel(ev);
      _cargandoNube = false;
    });
  }

  Future<void> _descargarPanel() async {
    final periodo = DateFormat('MMMM yyyy', 'es').format(_mes);
    await conEspera(context, () => PdfExport.panelHoras(porEdificio: _panel, periodo: periodo));
  }

  /// Arma el panel de horas desde los ingresos/salidas de la nube: turnos por
  /// puesto (celular), quién relevó a quién y la cuenta entre guardias.
  Map<String, List<PanelPuesto>> _calcularPanel(List<Map<String, dynamic>> eventos) {
    eventos.sort((a, b) => (a['created_at'] ?? '').toString().compareTo((b['created_at'] ?? '').toString()));
    final porEd = <String, List<RegistroTurno>>{};
    final abiertos = <String, Map<String, dynamic>>{}; // edificio|guardia -> ingreso
    final nombres = <String, String>{}; // puesto -> "Bloque A"
    for (final e in eventos) {
      final ed = (e['edificio'] ?? 'Sin edificio').toString();
      final g = (e['guardia'] ?? 'Sin nombre').toString();
      final tipo = (e['tipo'] ?? '').toString();
      DateTime? t;
      try { t = DateTime.parse(e['created_at'].toString()).toLocal(); } catch (_) {}
      if (t == null) continue;
      var det = e['detalle'];
      if (det is String && det.isNotEmpty) {
        try { det = jsonDecode(det); } catch (_) {}
      }
      final d = det is Map ? det : const {};
      final puesto = (e['device_id'] ?? 'sin-celular').toString();
      final bloque = (d['bloque'] ?? '').toString().trim();
      if (bloque.isNotEmpty) nombres[puesto] = bloque;
      final k = '$ed|$g';
      if (tipo == 'Ingreso de turno') {
        abiertos[k] = {
          'inicio': t,
          'puesto': puesto,
          'relevos': Turnos.limpiar((d['relevos'] ?? '').toString().split(',')),
        };
      } else if (tipo == 'Salida de turno') {
        final a = abiertos.remove(k);
        if (a == null) continue;
        final ini = a['inicio'] as DateTime;
        final h = t.difference(ini).inMinutes / 60.0;
        if (h <= 0 || h >= 60) continue;
        porEd.putIfAbsent(ed, () => []).add(RegistroTurno(
              guardia: g,
              puesto: a['puesto'] as String,
              inicio: ini,
              fin: t,
              nivelDeclarado: Turnos.nivelValido(d['nivel']),
              relevos: a['relevos'] as List<String>,
            ));
      }
    }
    // Turnos aún abiertos (en turno ahora), si empezaron hace menos de 40 h.
    final ahora = DateTime.now();
    for (final e in abiertos.entries) {
      final ini = e.value['inicio'] as DateTime;
      if (ahora.difference(ini).inHours > 40) continue; // olvidó marcar salida
      final ed = e.key.substring(0, e.key.indexOf('|'));
      porEd.putIfAbsent(ed, () => []).add(RegistroTurno(
            guardia: e.key.substring(e.key.indexOf('|') + 1),
            puesto: e.value['puesto'] as String,
            inicio: ini,
            relevos: e.value['relevos'] as List<String>,
          ));
    }
    final desde = DateTime(_mes.year, _mes.month), hasta = DateTime(_mes.year, _mes.month + 1);
    return {
      for (final e in porEd.entries)
        e.key: PanelHoras.calcular(e.value, nombres: nombres, desde: desde, hasta: hasta),
    }..removeWhere((_, v) => v.isEmpty);
  }

  /// Detalle de un guardia: resumen y cada turno del mes (día por día).
  void _detalleGuardia(PanelPuesto pu, ResumenGuardia r) {
    final dia = DateFormat('EEE dd/MM', 'es');
    final hm = DateFormat('HH:mm');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(r.guardia),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(shrinkWrap: true, children: [
            Text(pu.nombre, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _chip('Días', '${r.dias}', AppColors.azulMarino),
              _chip('12 h', '${r.n12}', const Color(0xFF1565C0)),
              _chip('24 h', '${r.n24}', AppColors.verde),
              _chip('36 h', '${r.n36}', const Color(0xFF6A1B9A)),
              _chip('Extra', r.extra.toStringAsFixed(1), const Color(0xFFEF6C00)),
              _chip('Tarde', '${r.vecesTarde}', AppColors.rojo),
            ]),
            const Divider(height: 20),
            for (final t in r.turnos)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${dia.format(t.inicio)} · turno ${t.nivel} h',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    'Ingreso ${hm.format(t.inicio)}${t.atraso > 0 ? ' (tarde ${t.atraso.toStringAsFixed(1)} h)' : ''}'
                    '  →  ${t.fin == null ? 'en turno' : 'Salida ${DateFormat('dd/MM HH:mm').format(t.fin!)}'}'
                    '${t.extra > 0 ? '\n+${t.extra.toStringAsFixed(1)} h extra · esperó a ${t.relevadoPor ?? 'su relevo'}' : ''}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ]),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
      ),
    );
  }

  /// Frase de la cuenta entre dos guardias.
  Widget _balance(BalancePar b) {
    final h = b.horas.toStringAsFixed(1);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: b.aMano ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(b.aMano ? Icons.handshake_outlined : Icons.balance, color: b.aMano ? AppColors.verde : const Color(0xFFEF6C00)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            b.aMano
                ? '${b.a} y ${b.b} están a mano'
                : 'Beneficiario: ${b.beneficiario} con $h h\n(le debe a ${b.acreedor})',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ]),
    );
  }

  Widget _chip(String label, String value, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color)),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ]),
      );

  bool _enLinea(Map<String, dynamic> p) {
    try {
      final ls = DateTime.parse(p['last_seen'].toString()).toUtc();
      return DateTime.now().toUtc().difference(ls).inMinutes < 5;
    } catch (_) {
      return false;
    }
  }

  /// Guardias en linea de este edificio segun la nube (todos los celulares).
  List<Map<String, dynamic>> get _enTurnoNube {
    final ed = AppState.instance.edificioId;
    return _presencia
        .where((p) => _enLinea(p) && p['en_turno'] == true && (p['edificio']?.toString() ?? '') == ed)
        .toList();
  }

  Future<void> _eliminarPersonal(Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.person_remove, color: AppColors.rojo, size: 36),
        title: const Text('Eliminar personal'),
        content: Text('¿Eliminar a "${p['nombre'] ?? ''}" del personal registrado?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // Baja en este celular y en los demás del edificio (sincronizado).
    await ConfigSync.darDeBaja(p['id'] as int, (p['nombre'] ?? '').toString());
    if (!mounted) return;
    TopToast.show(context, 'Personal eliminado');
    _load();
  }

  Future<void> _nuevoGuardia() async {
    final n = TextEditingController();
    final c = TextEditingController(text: 'Guardia de Seguridad');
    String rol = 'guardia';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Registrar guardia'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: n, decoration: const InputDecoration(labelText: 'Nombre completo')),
              const SizedBox(height: 8),
              TextField(controller: c, decoration: const InputDecoration(labelText: 'Cargo')),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: rol,
                decoration: const InputDecoration(labelText: 'Rol'),
                items: const [
                  DropdownMenuItem(value: 'guardia', child: Text('Guardia')),
                  DropdownMenuItem(value: 'franquero', child: Text('Franquero (temporal)')),
                  DropdownMenuItem(value: 'supervisor', child: Text('Supervisor')),
                  DropdownMenuItem(value: 'conserje', child: Text('Conserje')),
                  DropdownMenuItem(value: 'limpieza', child: Text('Limpieza')),
                ],
                onChanged: (v) => setD(() => rol = v ?? 'guardia'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Registrar')),
          ],
        ),
      ),
    );
    if (ok == true && n.text.trim().isNotEmpty) {
      await AuthService.crearGuardia(nombre: n.text.trim(), cargo: c.text, rol: rol);
      if (!mounted) return;
      TopToast.show(context, 'Guardia registrado');
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final admin = AppState.instance.isAdmin;
    // "En linea" preferimos la nube (todos los celulares); si no hay, lo local.
    final enTurnoNube = _enTurnoNube;
    // Sin conexión (edificio "solo local") se muestran los turnos de este celular.
    final usarNube = !AppState.instance.soloLocal;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Guardias'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _load,
          ),
          if (admin)
            IconButton(
              icon: const Icon(Icons.warning_amber),
              tooltip: 'Advertencias',
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AdvertenciasScreen())),
            ),
          if (admin)
            IconButton(
              icon: const Icon(Icons.assessment),
              tooltip: 'Reporte de personal (PDF)',
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const ReportePersonalScreen())),
            ),
        ],
      ),
      floatingActionButton: admin
          ? FloatingActionButton.extended(
              backgroundColor: AppColors.azulMarino,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.person_add),
              label: const Text('Registrar guardia'),
              onPressed: _nuevoGuardia,
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Row(children: [
              const Icon(Icons.wifi_tethering, color: AppColors.verde),
              const SizedBox(width: 8),
              Text('En línea ahora (${usarNube ? enTurnoNube.length : _activosLocal.length})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ]),
            const Text('En todos los celulares con la app (se actualiza al refrescar).',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            if (usarNube)
              ...(enTurnoNube.isEmpty
                  ? [const Card(child: ListTile(title: Text('Ningún guardia en línea ahora')))]
                  : [
                      for (final p in enTurnoNube)
                        Card(
                          child: ListTile(
                            leading: const CircleAvatar(
                                backgroundColor: Color(0x1A2E7D32),
                                child: Icon(Icons.shield, color: AppColors.verde)),
                            title: Text(p['guardia']?.toString() ?? '—',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text('${p['edificio'] ?? ''} · En turno'),
                            trailing: const Icon(Icons.circle, color: AppColors.verde, size: 12),
                          ),
                        ),
                    ])
            else if (_activosLocal.isEmpty)
              const Card(child: ListTile(title: Text('Ningún guardia con turno activo')))
            else
              for (final t in _activosLocal)
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                        backgroundColor: Color(0x1A2E7D32),
                        child: Icon(Icons.shield, color: AppColors.verde)),
                    title: Text(t['guardia_nombre']?.toString() ?? '—',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        'Ingreso: ${DateFormat('dd/MM HH:mm').format(DateTime.parse(t['created_at'] as String))}'
                        '${t['bateria'] != null ? ' · Bateria ${t['bateria']}%' : ''}'),
                    trailing: const Icon(Icons.circle, color: AppColors.verde, size: 12),
                  ),
                ),

            // El personal registrado (con usuarios) SOLO lo ve el administrador.
            if (admin) ...[
              const SizedBox(height: 20),
              Row(children: [
                const Icon(Icons.groups, color: AppColors.azulMarino),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Personal registrado (${_personal.length})',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ]),
              const SizedBox(height: 8),
              if (_personal.isEmpty)
                const Card(child: ListTile(title: Text('Sin personal registrado. Usa "Registrar guardia".'))),
              for (final p in _personal)
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                        backgroundColor: Color(0x1A0A335D),
                        child: Icon(Icons.person, color: AppColors.azulMarino)),
                    title: Text(p['nombre']?.toString() ?? '—',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text([p['cargo'], p['rol']]
                        .where((x) => (x ?? '').toString().trim().isNotEmpty)
                        .join(' · ')),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: AppColors.rojo),
                      tooltip: 'Eliminar',
                      onPressed: () => _eliminarPersonal(p),
                    ),
                  ),
                ),
              // PANEL DE HORAS (todos los edificios, por puesto) desde la nube.
              const SizedBox(height: 20),
              Row(children: [
                const Icon(Icons.query_stats, color: Color(0xFF00838F)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Panel de horas', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.picture_as_pdf),
                  tooltip: 'Descargar panel (PDF)',
                  onPressed: _panel.isEmpty ? null : _descargarPanel,
                ),
              ]),
              Row(children: [
                IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _cambiarMes(-1)),
                Expanded(
                  child: Text(DateFormat('MMMM yyyy', 'es').format(_mes),
                      textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _mes.isBefore(DateTime(DateTime.now().year, DateTime.now().month)) ? () => _cambiarMes(1) : null,
                ),
              ]),
              if (_cargandoNube && _panel.isEmpty)
                const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
              else if (_panel.isEmpty)
                const Card(child: ListTile(title: Text('Sin turnos en este mes')))
              else
                for (final ed in (_panel.keys.toList()..sort()))
                  for (final pu in _panel[ed]!) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                      child: Text('$ed · ${pu.nombre}',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.azulMarino)),
                    ),
                    for (final b in pu.balances) _balance(b),
                    for (final r in (pu.guardias.values.toList()..sort((a, b) => a.guardia.compareTo(b.guardia))))
                      Card(
                        child: ListTile(
                          onTap: () => _detalleGuardia(pu, r),
                          leading: CircleAvatar(
                            backgroundColor: AppColors.verde.withOpacity(.12),
                            child: Text('${r.dias}', style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.verde)),
                          ),
                          title: Text(r.guardia, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('12 h: ${r.n12} · 24 h: ${r.n24} · 36 h: ${r.n36}\n'
                              'Extra ${r.extra.toStringAsFixed(1)} h · tarde ${r.vecesTarde} ${r.vecesTarde == 1 ? 'vez' : 'veces'}'),
                          isThreeLine: true,
                          trailing: const Icon(Icons.chevron_right),
                        ),
                      ),
                  ],
            ] else ...[
              const SizedBox(height: 24),
              const Card(
                child: ListTile(
                  leading: Icon(Icons.lock, color: Colors.blueGrey),
                  title: Text('Personal y registro'),
                  subtitle: Text('Solo el administrador puede ver el personal y registrar guardias.'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
