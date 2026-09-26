import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/app_state.dart';
import '../services/cloud.dart';
import '../services/config_sync.dart';
import '../services/guardias_service.dart';
import '../services/horas_local.dart';
import '../services/panel_horas.dart';
import '../services/pdf_export.dart';
import '../services/turnos.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/evento_tile.dart';
import '../widgets/toast.dart';

/// GUARDIAS del edificio elegido en Configuración. Cada edificio tiene los
/// suyos; el ID de cada guardia es su CI.
class GuardiasScreen extends StatefulWidget {
  const GuardiasScreen({super.key});
  @override
  State<GuardiasScreen> createState() => _GuardiasScreenState();
}

class _GuardiasScreenState extends State<GuardiasScreen> {
  List<Guardia> _guardias = [];
  Map<String, ResumenGuardia> _horas = {}; // CI → horas del mes
  bool _cargando = true;
  bool _sinSenal = false;
  bool _verBajas = false;
  DateTime _mes = DateTime(DateTime.now().year, DateTime.now().month);
  int _carga = 0;

  String get _ed => AppState.instance.edificioId;
  String get _periodo => DateFormat('MMMM yyyy', 'es').format(_mes);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final carga = ++_carga;
    final mes = _mes;
    setState(() => _cargando = true);
    // Primero lo del celular (al instante); después lo que llegó de la nube.
    await _leer(carga, mes);
    try {
      await ConfigSync.sincronizarGuardias(forzar: true);
    } catch (_) {}
    await _leer(carga, mes);
  }

  Future<void> _leer(int carga, DateTime mes) async {
    final lista = await GuardiasService.delEdificio(_ed, incluirInactivos: true);
    HorasEdificio? h;
    try {
      h = await HorasPanel.edificio(mes);
    } catch (_) {}
    if (!mounted || carga != _carga) return;
    setState(() {
      _guardias = lista;
      if (h != null) {
        _horas = PanelHoras.porGuardia(h.puestos);
        _sinSenal = h.local && !AppState.instance.soloLocal;
      }
      _cargando = false;
    });
  }

  void _cambiarMes(int d) {
    setState(() => _mes = DateTime(_mes.year, _mes.month + d));
    _load();
  }

  Future<void> _registrar() async {
    final s = AppState.instance;
    final nombre = TextEditingController();
    final ci = TextEditingController();
    final bloques = s.torres.length > 1 ? s.torres : const <String>[];
    String bloque = bloques.isNotEmpty ? (bloques.contains(s.bloque) ? s.bloque : bloques.first) : '';
    String turno = 'DIURNO';
    String? error;
    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          title: const Text('Registrar guardia'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Edificio: ${s.edificioNombre}', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            TextField(
              controller: nombre,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre completo'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: ci,
              keyboardType: TextInputType.text,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'CI (será su ID)'),
            ),
            // Edificio solo (sin bloques): no se pide bloque.
            if (bloques.isNotEmpty) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: bloque,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Bloque'),
                items: [for (final b in bloques) DropdownMenuItem(value: b, child: Text(b))],
                onChanged: (v) => setD(() => bloque = v ?? bloque),
              ),
            ],
            const SizedBox(height: 10),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'DIURNO', label: Text('Diurno')),
                ButtonSegment(value: 'NOCTURNO', label: Text('Nocturno')),
                ButtonSegment(value: 'FRANQUERO', label: Text('Franquero')),
              ],
              selected: {turno},
              onSelectionChanged: (v) => setD(() => turno = v.first),
            ),
            if (turno == 'FRANQUERO')
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Cubre permisos y faltas de los guardias de turno.',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error ?? '', style: const TextStyle(color: AppColors.rojo, fontWeight: FontWeight.w600)),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () async {
                final r = await GuardiasService.registrar(
                    nombre: nombre.text, ci: ci.text, turno: turno, bloque: bloque);
                if (!ctx.mounted) return;
                if (r != null) {
                  setD(() => error = r);
                  return;
                }
                Navigator.pop(ctx);
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    _load();
  }

  Widget _dato(String etiqueta, String valor, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: color.withOpacity(.10), borderRadius: BorderRadius.circular(10)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(valor, maxLines: 1, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
          Text(etiqueta, maxLines: 1, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ]),
      );

  Color _colorSaldo(double h) {
    final m = (h * 60).round();
    return m > 0 ? AppColors.verde : (m < 0 ? AppColors.rojo : Colors.blueGrey);
  }

  Widget _tarjeta(Guardia g) {
    final r = _horas[g.ci];
    final saldo = r?.saldo ?? 0;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () async {
          await Navigator.push(
              context, MaterialPageRoute(builder: (_) => GuardiaDetalleScreen(guardia: g, mes: _mes, resumen: r)));
          if (mounted) _load();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Text(g.nombre.toUpperCase(),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                        color: g.activo ? AppColors.azulMarino : Colors.grey)),
              ),
              const Icon(Icons.chevron_right, color: Colors.black38),
            ]),
            Text(
              'ID ${g.ci} · ${g.turnoTexto}${g.bloque.isEmpty ? '' : ' · ${g.bloque}'}${g.activo ? '' : ' · de baja'}',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _dato('Horas extras', Turnos.saldo(saldo), _colorSaldo(saldo)),
              _dato('Días trabajados', '${r?.dias ?? 0}', AppColors.azulMarino),
              _dato('36 h', '${r?.n36 ?? 0}', const Color(0xFF6A1B9A)),
              _dato('24 h', '${r?.n24 ?? 0}', const Color(0xFF00695C)),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activos = _guardias.where((g) => g.activo).toList();
    final bajas = _guardias.where((g) => !g.activo).toList();
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Guardias', style: TextStyle(fontSize: 17)),
          Text(AppState.instance.edificioNombre,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ]),
        actions: [IconButton(icon: const Icon(Icons.refresh), tooltip: 'Actualizar', onPressed: _load)],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _registrar,
                icon: const Icon(Icons.person_add),
                label: const Text('REGISTRAR GUARDIA'),
              ),
            ),
            const SizedBox(height: 6),
            Row(children: [
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _cambiarMes(-1)),
              Expanded(
                child: Text(_periodo, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed:
                    _mes.isBefore(DateTime(DateTime.now().year, DateTime.now().month)) ? () => _cambiarMes(1) : null,
              ),
            ]),
            if (_sinSenal)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text('Sin conexión: horas solo de los turnos de este celular.',
                    style: TextStyle(fontSize: 12, color: Color(0xFFEF6C00))),
              ),
            if (_cargando && _guardias.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (activos.isEmpty)
              const Card(child: ListTile(title: Text('No hay guardias registrados en este edificio.'))),
            for (final g in activos) _tarjeta(g),
            if (bajas.isNotEmpty) ...[
              TextButton.icon(
                onPressed: () => setState(() => _verBajas = !_verBajas),
                icon: Icon(_verBajas ? Icons.expand_less : Icons.expand_more),
                label: Text('Dados de baja (${bajas.length})'),
              ),
              if (_verBajas) ...[for (final g in bajas) _tarjeta(g)],
            ],
          ],
        ),
      ),
    );
  }
}

/// Todo lo de UN guardia en el mes: ingresos y salidas, rondas, incidentes,
/// visitas y advertencias, para ver o descargar.
class GuardiaDetalleScreen extends StatefulWidget {
  final Guardia guardia;
  final DateTime mes;
  final ResumenGuardia? resumen;
  const GuardiaDetalleScreen({super.key, required this.guardia, required this.mes, this.resumen});
  @override
  State<GuardiaDetalleScreen> createState() => _GuardiaDetalleScreenState();
}

class _GuardiaDetalleScreenState extends State<GuardiaDetalleScreen> {
  List<Map<String, dynamic>> _registros = [];
  bool _cargando = true;

  Guardia get g => widget.guardia;
  String get _periodo => DateFormat('MMMM yyyy', 'es').format(widget.mes);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await Cloud.registrosGuardia(g.edificio, g.ci, widget.mes);
    l.sort((a, b) => (Cloud.horaEvento(b) ?? DateTime(0)).compareTo(Cloud.horaEvento(a) ?? DateTime(0)));
    if (!mounted) return;
    setState(() {
      _registros = l;
      _cargando = false;
    });
  }

  List<Map<String, dynamic>> _de(Set<String> tipos) => _registros.where((e) => tipos.contains(e['tipo'])).toList();

  Future<void> _pdf() => conEspera(
      context,
      () => PdfExport.guardiaPdf(
            g: g,
            periodo: _periodo,
            resumen: widget.resumen,
            registros: _registros,
          ));

  Future<void> _baja() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Dar de baja a ${g.nombre}'),
        content: const Text('Deja de aparecer para iniciar turno. Su historial y sus horas se conservan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Dar de baja'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await GuardiasService.darDeBaja(g);
    if (!mounted) return;
    TopToast.show(context, '${g.nombre} dado de baja');
    Navigator.pop(context);
  }

  /// Eliminar del edificio (y opcionalmente sus registros de la nube de
  /// ESTE edificio).
  Future<void> _eliminar() async {
    bool borrarDatos = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          icon: const Icon(Icons.delete_forever, color: AppColors.rojo, size: 36),
          title: Text('Eliminar a ${g.nombre}'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Se quita de ${g.edificio} en todos los celulares. No se puede deshacer.'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: borrarDatos,
              onChanged: (v) => setD(() => borrarDatos = v ?? false),
              title: const Text('Borrar también sus registros de la nube'),
              subtitle: Text('Solo de ${g.edificio}: ingresos, salidas, rondas, visitas, incidentes.'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    String? error;
    await conEspera(context, () async {
      error = await GuardiasService.eliminar(g, borrarDatos: borrarDatos);
    }, mensaje: 'Eliminando…', error: 'No se pudo eliminar');
    if (!mounted) return;
    final e = error;
    if (e != null) {
      TopToast.show(context, e, color: AppColors.rojo, icon: Icons.error_outline);
      return;
    }
    TopToast.show(context, '${g.nombre} eliminado');
    Navigator.pop(context);
  }

  Widget _dato(String etiqueta, String valor, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: color.withOpacity(.10), borderRadius: BorderRadius.circular(10)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(valor, maxLines: 1, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
          Text(etiqueta, maxLines: 1, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ]),
      );

  Widget _seccion(String titulo, IconData icon, List<Widget> hijos) => Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          leading: Icon(icon, color: AppColors.azulMarino),
          title: Text('$titulo (${hijos.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
          children: hijos.isEmpty ? [const ListTile(dense: true, title: Text('Sin registros este mes'))] : hijos,
        ),
      );

  Widget _turno(RegistroTurno t) {
    final dhm = DateFormat('dd/MM HH:mm');
    return ListTile(
      dense: true,
      title: Text(
          '${DateFormat('EEE dd/MM', 'es').format(t.inicio)} · ${t.valido ? 'Turno ${t.nivel} h' : t.estado}'
          '${t.movimientos.isEmpty ? '' : ' · ${Turnos.saldo(t.saldo)}'}',
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text([
        'Ingreso ${dhm.format(t.inicio)} → Salida ${t.fin == null ? '—' : dhm.format(t.fin!)}',
        for (final m in t.movimientos) '${Turnos.saldo(m.horas)} ${m.motivo}${m.con != null ? ' (${m.con})' : ''}',
      ].join('\n')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.resumen;
    final turnos = (r?.turnos ?? const <RegistroTurno>[]).toList()..sort((a, b) => b.inicio.compareTo(a.inicio));
    final saldo = r?.saldo ?? 0;
    final m = (saldo * 60).round();
    final color = m > 0 ? AppColors.verde : (m < 0 ? AppColors.rojo : Colors.blueGrey);
    return Scaffold(
      appBar: AppBar(
        title: Text(g.nombre, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(icon: const Icon(Icons.picture_as_pdf), tooltip: 'Descargar PDF', onPressed: _cargando ? null : _pdf),
          if (AppState.instance.isAdmin)
            PopupMenuButton<String>(
              onSelected: (v) => v == 'baja' ? _baja() : _eliminar(),
              itemBuilder: (_) => [
                if (g.activo)
                  const PopupMenuItem(
                      value: 'baja', child: ListTile(leading: Icon(Icons.person_off_outlined), title: Text('Dar de baja'))),
                const PopupMenuItem(
                    value: 'eliminar',
                    child: ListTile(
                        leading: Icon(Icons.delete_forever, color: AppColors.rojo), title: Text('Eliminar guardia'))),
              ],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('ID ${g.ci} · ${g.turnoTexto}${g.bloque.isEmpty ? '' : ' · ${g.bloque}'}',
                    style: const TextStyle(color: Colors.black54)),
                Text('${g.edificio} · $_periodo', style: const TextStyle(color: Colors.black54, fontSize: 12)),
                const SizedBox(height: 8),
                Text(Turnos.saldo(saldo), style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color)),
                Text(m > 0 ? 'Horas extras a favor' : (m < 0 ? 'Horas en contra' : 'Equilibrado'),
                    style: TextStyle(color: color, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  _dato('Días trabajados', '${r?.dias ?? 0}', AppColors.azulMarino),
                  _dato('Horas', (r?.horas ?? 0).toStringAsFixed(1), AppColors.azulMarino),
                  _dato('36 h', '${r?.n36 ?? 0}', const Color(0xFF6A1B9A)),
                  _dato('24 h', '${r?.n24 ?? 0}', const Color(0xFF00695C)),
                ]),
              ]),
            ),
          ),
          if (_cargando) const LinearProgressIndicator(),
          _seccion('Ingresos y salidas', Icons.login, [for (final t in turnos) _turno(t)]),
          _seccion('Rondas', Icons.directions_walk, [for (final e in _de({'Ronda'})) EventoTile(e)]),
          _seccion('Incidentes', Icons.warning_amber, [for (final e in _de({'Incidente'})) EventoTile(e)]),
          _seccion('Visitas', Icons.badge, [for (final e in _de({'Visita'})) EventoTile(e)]),
          _seccion('Advertencias', Icons.report_problem_outlined,
              [for (final e in _de({'Advertencia', 'Guardia sin uniforme'})) EventoTile(e)]),
        ],
      ),
    );
  }
}
