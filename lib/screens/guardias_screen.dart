import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/auth_service.dart';
import '../services/cloud.dart';
import '../services/config_sync.dart';
import '../services/horas_local.dart';
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
  bool _soloEsteCelular = false; // sin señal: se muestran solo los turnos de este celular
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
    });
    if (!AppState.instance.soloLocal) {
      Cloud.heartbeat();
      Cloud.presencia(edificio: ed).then((pres) {
        if (mounted) setState(() => _presencia = pres);
      });
    }
    await _cargarPanel();
  }

  int _cargaPanel = 0;

  /// Carga las horas del mes elegido. Si se cambia de mes mientras carga,
  /// el resultado viejo se descarta (antes podía mostrar otro mes).
  Future<void> _cargarPanel() async {
    final carga = ++_cargaPanel;
    final mes = _mes;
    setState(() => _cargandoNube = true);
    Map<String, List<PanelPuesto>> panel = {};
    bool local = AppState.instance.soloLocal;
    try {
      if (!local) {
        // Primero se envía lo pendiente de este celular (así sus propios
        // ingresos/salidas y correcciones ya cuentan).
        await Cloud.vaciarCola();
        panel = PanelHoras.panelNube(await Cloud.eventosTurnoMes(mes: mes, lanzar: true), mes,
            tolerancias: await _tolerancias());
      }
    } catch (_) {
      local = true; // sin señal: al menos lo de este celular
    }
    if (local) {
      try {
        final l = await HorasPanel.local(mes);
        panel = l.isEmpty ? {} : {AppState.instance.edificioId: l};
      } catch (_) {}
    }
    if (!mounted || carga != _cargaPanel) return;
    setState(() {
      _panel = panel;
      _soloEsteCelular = local && !AppState.instance.soloLocal;
      _cargandoNube = false;
    });
  }

  /// Tolerancia de cada edificio (su configuración, sincronizada desde la
  /// nube por el admin).
  Future<Map<String, int>> _tolerancias() async {
    final out = <String, int>{};
    try {
      final db = await DB.instance.database;
      for (final e in await db.query('edificios', columns: ['id', 'modulos'])) {
        Map? m;
        try {
          final d = jsonDecode('${e['modulos'] ?? ''}');
          if (d is Map) m = d;
        } catch (_) {}
        out['${e['id']}'] = Turnos.toleranciaDe(m);
      }
    } catch (_) {}
    out[AppState.instance.edificioId] = AppState.instance.toleranciaMin;
    return out;
  }

  /// Cambia el mes del panel de horas (solo recarga las horas).
  void _cambiarMes(int delta) {
    setState(() {
      _mes = DateTime(_mes.year, _mes.month + delta);
      _panel = {};
    });
    _cargarPanel();
  }

  Future<void> _descargarPanel() async {
    final periodo = DateFormat('MMMM yyyy', 'es').format(_mes);
    await conEspera(context, () => PdfExport.panelHoras(
        porEdificio: _panel,
        periodo: periodo,
        nota: _soloEsteCelular ? 'Sin conexion al generar: solo incluye los turnos registrados en este celular.' : null));
  }

  /// Resumen de un guardia en un edificio (todos sus puestos).
  ResumenGuardia? _resumen(String edificio, String guardia) =>
      PanelHoras.porGuardia(_panel[edificio] ?? const [])[guardia];

  /// Nombre visible de cada puesto (celular) de un edificio.
  Map<String, String> _nombresPuestos(String edificio) =>
      {for (final p in _panel[edificio] ?? const <PanelPuesto>[]) p.puesto: p.nombre};

  /// Saldo junto al guardia: "+3 h 30 min" (a favor), "-1 h" (en contra),
  /// "0 h" (equilibrado).
  Widget _saldoChip(double saldo) {
    final m = (saldo * 60).round();
    final color = m > 0 ? AppColors.verde : (m < 0 ? AppColors.rojo : Colors.blueGrey);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withOpacity(.12), borderRadius: BorderRadius.circular(20)),
      child: Text(Turnos.saldo(saldo),
          maxLines: 1, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
    );
  }

  /// Historial COMPLETO de un guardia (se abre al tocar su tarjeta).
  void _historial(String edificio, String guardia) {
    final r = _resumen(edificio, guardia) ?? ResumenGuardia(guardia);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _HistorialGuardia(
          resumen: r,
          edificio: edificio,
          periodo: DateFormat('MMMM yyyy', 'es').format(_mes),
          puestos: _nombresPuestos(edificio),
          toleranciaMin: (_panel[edificio]?.isNotEmpty ?? false)
              ? _panel[edificio]!.first.toleranciaMin
              : AppState.instance.toleranciaMin,
          // Las correcciones van a la nube (quedan registradas y auditables).
          onCorregir: AppState.instance.isAdmin && !AppState.instance.soloLocal && !_soloEsteCelular
              ? _corregir
              : null,
        ),
      ),
    );
  }

  /// Corrección MANUAL de un turno (solo admin). No modifica los registros
  /// originales: agrega un evento "Corrección de turno" con el id del turno;
  /// la última corrección reemplaza a las anteriores, así no se duplican horas.
  Future<bool> _corregir(RegistroTurno t) async {
    DateTime ini = t.inicio;
    DateTime? fin = t.fin;
    int nivel = t.nivel;
    bool anular = false;
    final motivo = TextEditingController();
    final f = DateFormat('EEE dd/MM HH:mm', 'es');

    Future<DateTime?> elegir(BuildContext ctx, DateTime base) async {
      final d = await showDatePicker(
          context: ctx,
          initialDate: base,
          firstDate: base.subtract(const Duration(days: 60)),
          lastDate: DateTime.now().add(const Duration(days: 2)));
      if (d == null || !ctx.mounted) return null;
      final h = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(base));
      if (h == null) return null;
      return DateTime(d.year, d.month, d.day, h.hour, h.minute);
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          title: Text('Corregir turno · ${t.guardia}'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.login, color: AppColors.verde),
              title: const Text('Ingreso'),
              subtitle: Text(f.format(ini)),
              onTap: anular ? null : () async {
                final v = await elegir(ctx, ini);
                if (v != null) setD(() => ini = v);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.logout, color: AppColors.rojo),
              title: const Text('Salida'),
              subtitle: Text(fin == null ? 'Sin salida (tocar para poner)' : f.format(fin!)),
              onTap: anular ? null : () async {
                final v = await elegir(ctx, fin ?? ini.add(Duration(hours: nivel)));
                if (v != null) setD(() => fin = v);
              },
            ),
            const SizedBox(height: 6),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 12, label: Text('12 h')),
                ButtonSegment(value: 24, label: Text('24 h')),
                ButtonSegment(value: 36, label: Text('36 h')),
              ],
              selected: {nivel},
              onSelectionChanged: anular ? null : (v) => setD(() => nivel = v.first),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: anular,
              onChanged: (v) => setD(() => anular = v ?? false),
              title: const Text('Anular este registro'),
              subtitle: const Text('Duplicado o marcado por error'),
            ),
            TextField(
              controller: motivo,
              decoration: const InputDecoration(labelText: 'Motivo *'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () {
                if (motivo.text.trim().isEmpty) return;
                if (!anular && fin != null && !fin!.isAfter(ini)) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    // (el controlador es local; no se libera aquí porque el diálogo todavía
    // se está cerrando y el campo lo usa al perder el foco)
    final texto = motivo.text.trim();
    if (ok != true || !mounted) return false;
    await conEspera(context, () async {
      await Cloud.evento('Corrección de turno',
          guardia: t.guardia,
          edificio: t.edificio,
          detalle: {
            'turno_ref': t.id,
            'anular': anular,
            'inicio': ini.toUtc().toIso8601String(),
            if (fin != null) 'fin': fin!.toUtc().toIso8601String(),
            'nivel': nivel,
            'motivo': texto,
            'antes': '${f.format(t.inicio)} → ${t.fin == null ? '-' : f.format(t.fin!)} (${t.nivel} h)',
          });
      await Cloud.vaciarCola();
    }, mensaje: 'Guardando corrección…', error: 'No se pudo guardar la corrección');
    if (!mounted) return false;
    final pendientes = await Cloud.pendientes();
    if (!mounted) return false;
    TopToast.show(context, pendientes > 0 ? 'Corrección guardada; se enviará al volver la señal' : 'Corrección guardada');
    await _cargarPanel();
    return true;
  }

  /// Frase de la cuenta entre dos guardias.
  Widget _balance(BalancePar b) {
    final h = Turnos.saldo(b.horas).replaceFirst('+', '');
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
                : 'Beneficiario: ${b.beneficiario} con $h\n(le debe a ${b.acreedor})',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ]),
    );
  }

  String _fechaHora(Object? iso) {
    final d = DateTime.tryParse('${iso ?? ''}');
    return d == null ? '—' : DateFormat('dd/MM HH:mm').format(d);
  }

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
                isExpanded: true, // texto largo con "…" en vez de desbordar
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

  /// Tarjeta del guardia (la existente) con su saldo del mes al lado; al
  /// tocarla se abre su historial completo.
  Widget _tarjetaPersonal(Map<String, dynamic> p) {
    final nombre = p['nombre']?.toString() ?? '—';
    final ed = AppState.instance.edificioId;
    final r = _resumen(ed, nombre);
    return Card(
      child: ListTile(
        onTap: () => _historial(ed, nombre),
        leading: const CircleAvatar(
            backgroundColor: Color(0x1A0A335D),
            child: Icon(Icons.person, color: AppColors.azulMarino)),
        title: Text(nombre, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
            [p['cargo'], p['rol']].where((x) => (x ?? '').toString().trim().isNotEmpty).join(' · '),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (r != null) _saldoChip(r.saldo),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: AppColors.rojo),
            tooltip: 'Eliminar',
            onPressed: () => _eliminarPersonal(p),
          ),
        ]),
      ),
    );
  }

  /// Resumen de un edificio: cuentas entre pares y guardias ordenados por
  /// saldo (a favor arriba, en contra abajo).
  List<Widget> _resumenEdificio(String ed) {
    final puestos = _panel[ed] ?? const <PanelPuesto>[];
    final guardias = PanelHoras.porGuardia(puestos).values.toList()
      ..sort((a, b) {
        final c = b.saldo.compareTo(a.saldo);
        return c != 0 ? c : a.guardia.compareTo(b.guardia);
      });
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
        child: Text(
            puestos.length == 1 ? '$ed · ${puestos.first.nombre}' : '$ed · ${puestos.length} puestos',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.azulMarino)),
      ),
      for (final pu in puestos)
        for (final b in pu.balances) _balance(b),
      for (final r in guardias)
        Card(
          child: ListTile(
            onTap: () => _historial(ed, r.guardia),
            title: Text(r.guardia, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              'A favor ${Turnos.saldo(r.aFavor).replaceFirst('+', '')} · '
              'En contra ${Turnos.saldo(r.enContra).replaceFirst('+', '')}\n'
              '${r.dias} días · 12 h: ${r.n12} · 24 h: ${r.n24} · 36 h: ${r.n36}'
              '${r.incompletos > 0 ? ' · ${r.incompletos} incompleto${r.incompletos == 1 ? '' : 's'}' : ''}',
              maxLines: 2, overflow: TextOverflow.ellipsis,
            ),
            isThreeLine: true,
            trailing: _saldoChip(r.saldo),
          ),
        ),
    ];
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
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
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
                        'Ingreso: ${_fechaHora(t['created_at'])}'
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
              for (final p in _personal) _tarjetaPersonal(p),
              // RESUMEN DE HORAS: quién tiene horas a favor y quién en contra
              // (para pago o compensación). Mismo cálculo que el historial y el PDF.
              const SizedBox(height: 20),
              Row(children: [
                const Icon(Icons.query_stats, color: Color(0xFF00838F)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Horas a favor / en contra',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
              if (_soloEsteCelular)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text('Sin conexión: solo los turnos de este celular.',
                      style: TextStyle(fontSize: 12, color: Color(0xFFEF6C00))),
                ),
              if (_cargandoNube && _panel.isEmpty)
                const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
              else if (_panel.isEmpty)
                const Card(child: ListTile(title: Text('Sin turnos en este mes')))
              else
                for (final ed in (_panel.keys.toList()..sort())) ..._resumenEdificio(ed),
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


/// Historial completo de un guardia en el periodo: cada turno con fecha,
/// ingreso y salida reales, tipo (12/24/36 h), las horas a favor / en contra
/// que generó y de qué registro salió cada una (auditoría).
class _HistorialGuardia extends StatefulWidget {
  final ResumenGuardia resumen;
  final String edificio;
  final String periodo;
  final Map<String, String> puestos;
  final int toleranciaMin;
  final Future<bool> Function(RegistroTurno t)? onCorregir;
  const _HistorialGuardia({
    required this.toleranciaMin,
    required this.resumen,
    required this.edificio,
    required this.periodo,
    required this.puestos,
    this.onCorregir,
  });

  @override
  State<_HistorialGuardia> createState() => _HistorialGuardiaState();
}

class _HistorialGuardiaState extends State<_HistorialGuardia> {
  static final _dia = DateFormat('EEE dd/MM', 'es');
  static final _hm = DateFormat('HH:mm');
  static final _dhm = DateFormat('EEE dd/MM HH:mm', 'es');

  Color _color(double h) {
    final m = (h * 60).round();
    return m > 0 ? AppColors.verde : (m < 0 ? AppColors.rojo : Colors.blueGrey);
  }

  Widget _dato(String valor, String etiqueta, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(valor, maxLines: 1, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
          Text(etiqueta, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ]),
      );

  String _estado(RegistroTurno t) {
    switch (t.estado) {
      case 'abierto':
        return 'En turno';
      case 'sin salida':
        return 'Sin salida · no se calcula';
      case 'sin ingreso':
        return 'Sin ingreso · no se calcula';
      case 'anulado':
        return 'Anulado';
      case 'inconsistente':
        return 'Registro inconsistente · no se calcula';
      default:
        return '';
    }
  }

  Widget _turno(RegistroTurno t) {
    final estado = _estado(t);
    final puesto = widget.puestos[t.puesto];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                '${_dia.format(t.inicio)} · ${t.valido ? 'Turno ${t.nivel} h' : 'Registro'}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (t.valido && t.movimientos.isNotEmpty)
              Text(Turnos.saldo(t.saldo),
                  style: TextStyle(fontWeight: FontWeight.bold, color: _color(t.saldo))),
            if (widget.onCorregir != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_calendar_outlined, size: 20),
                tooltip: 'Corregir',
                onPressed: () async {
                  final ok = await widget.onCorregir!(t);
                  if (ok && mounted) Navigator.pop(context); // el panel se recalculó
                },
              ),
          ]),
          Text(
            'Ingreso ${_dhm.format(t.inicio)}\n'
            'Salida ${t.fin == null ? '—' : _dhm.format(t.fin!)}'
            '${t.cerrado ? ' · ${Turnos.duracion(t.fin!.difference(t.inicio))}' : ''}',
            style: const TextStyle(fontSize: 13),
          ),
          if (t.progInicio != null)
            Text(
              'Programado ${_hm.format(t.progInicio!)} → ${_dhm.format(t.progFin!)}'
              '${puesto != null ? ' · $puesto' : ''}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          if (estado.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(estado,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: t.estado == 'abierto' ? AppColors.verde : const Color(0xFFEF6C00))),
            ),
          for (final m in t.movimientos)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${Turnos.saldo(m.horas)} · ${m.motivo}'
                '${m.con != null ? ' (${m.con})' : ''} · relevo ${_hm.format(m.programado)}, '
                'real ${_hm.format(m.real)}',
                style: TextStyle(fontSize: 12.5, color: _color(m.horas), fontWeight: FontWeight.w600),
              ),
            ),
          // Auditoría: de qué registros salió este turno.
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              [
                if (t.refIngreso != null) 'Ingreso: ${t.refIngreso}',
                if (t.refSalida != null) 'Salida: ${t.refSalida}',
                ...t.notas,
              ].join('\n'),
              style: const TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.resumen;
    final turnos = r.turnos.toList()..sort((a, b) => b.inicio.compareTo(a.inicio));
    final saldo = r.saldo;
    final m = (saldo * 60).round();
    return Scaffold(
      appBar: AppBar(title: Text(r.guardia, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('${widget.edificio} · ${widget.periodo}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 6),
                Text(Turnos.saldo(saldo),
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: _color(saldo))),
                Text(m > 0 ? 'Horas a favor' : (m < 0 ? 'Horas en contra' : 'Equilibrado'),
                    style: TextStyle(color: _color(saldo), fontWeight: FontWeight.w600)),
                Text('Tolerancia ${widget.toleranciaMin} min: pasado ese margen cuentan todos los minutos',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _dato(Turnos.saldo(r.aFavor).replaceFirst('+', ''), 'A favor', AppColors.verde),
                  _dato(Turnos.saldo(r.enContra).replaceFirst('+', ''), 'En contra', AppColors.rojo),
                  _dato('${r.dias}', 'Días', AppColors.azulMarino),
                  _dato('${r.n12}', '12 h', const Color(0xFF1565C0)),
                  _dato('${r.n24}', '24 h', AppColors.verde),
                  _dato('${r.n36}', '36 h', const Color(0xFF6A1B9A)),
                  _dato('${r.vecesTarde}', 'Tarde', AppColors.rojo),
                ]),
              ]),
            ),
          ),
          if (turnos.isEmpty)
            const Card(child: ListTile(title: Text('Sin turnos en este periodo'))),
          for (final t in turnos) _turno(t),
        ],
      ),
    );
  }
}
