import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/app_state.dart';
import '../services/cloud.dart';
import '../services/estructura.dart';
import '../services/guardias_repo.dart';
import '../services/horas_local.dart';
import '../services/panel_horas.dart';
import '../services/pdf_export.dart';
import '../services/sesion.dart';
import '../services/turnos.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/toast.dart';
import 'config_screen.dart';
import 'guardias_anterior_screen.dart';
import 'historial_guardia.dart';

/// GUARDIAS del edificio seleccionado en Configuración (contexto global).
/// Estructura: EDIFICIO → UNIDAD (torre/dispositivo) → GUARDIA (id único)
/// → sus registros. Cada unidad tiene 1 guardia diurno y 1 nocturno.
class GuardiasScreen extends StatefulWidget {
  const GuardiasScreen({super.key});
  @override
  State<GuardiasScreen> createState() => _GuardiasScreenState();
}

class _GuardiasScreenState extends State<GuardiasScreen> {
  List<Guardia> _guardias = [];
  Map<String, ResumenGuardia> _horas = {};           // guard_id → horas del mes
  List<PanelPuesto> _puestos = [];
  final Map<String, Map<String, int>> _conteos = {}; // guard_id → tipo → cantidad
  Map<String, int> _adv = {};                        // guard_id → advertencias activas
  DateTime _mes = DateTime(DateTime.now().year, DateTime.now().month);
  bool _cargando = false;
  bool _sinSenal = false;
  bool _verInactivos = false;
  String? _error;
  int _carga = 0;

  String get _ed => AppState.instance.edificioId;
  String get _edNombre => AppState.instance.edificioNombre;
  String? get _bid => Estructura.idEdificio(_ed);
  List<Unidad> get _unidades => Estructura.unidades(_bid);
  String get _periodo => DateFormat('MMMM yyyy', 'es').format(_mes);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!Sesion.vinculado) {
      setState(() {});
      return;
    }
    final carga = ++_carga;
    final mes = _mes;
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      await Estructura.actualizar();
      // El edificio de Configuración todavía no está en la nube: el admin lo publica.
      if (_bid == null && Sesion.esAdmin) await Estructura.publicarEdificio(_ed, _edNombre);
      final bid = _bid;
      if (bid == null) {
        if (!mounted || carga != _carga) return;
        setState(() {
          _cargando = false;
          _error = 'Este edificio no está en la nube todavía. Revisa la conexión y actualiza.';
        });
        return;
      }
      final res = await Future.wait<Object>([
        GuardiasRepo.delEdificio(bid),
        HorasPanel.edificio(mes),
        GuardiasRepo.advertenciasActivas(bid),
        Cloud.registrosGuardiasMes(_ed, mes),
      ]);
      final guardias = res[0] as List<Guardia>;
      final horas = res[1] as HorasEdificio;
      final adv = res[2] as Map<String, int>;
      final regs = res[3] as List<Map<String, dynamic>>;
      final conteos = <String, Map<String, int>>{};
      for (final e in regs) {
        final g = '${e['guard_id']}';
        final t = '${e['tipo']}';
        final m = conteos.putIfAbsent(g, () => {});
        m[t] = (m[t] ?? 0) + 1;
      }
      if (!mounted || carga != _carga) return;
      setState(() {
        _guardias = guardias;
        _puestos = horas.puestos;
        _horas = PanelHoras.porGuardia(horas.puestos);
        _sinSenal = horas.local && !AppState.instance.soloLocal;
        _adv = adv;
        _conteos
          ..clear()
          ..addAll(conteos);
        _cargando = false;
      });
    } catch (e) {
      if (!mounted || carga != _carga) return;
      setState(() {
        _cargando = false;
        _error = 'No se pudo cargar: $e';
      });
    }
  }

  void _cambiarMes(int delta) {
    setState(() => _mes = DateTime(_mes.year, _mes.month + delta));
    _load();
  }

  // ---------------------------------------------------------------------------
  // Acciones
  // ---------------------------------------------------------------------------

  Guardia? _activoEn(String unitId, String turno) {
    for (final g in _guardias) {
      if (g.activo && g.rol == 'guardia' && g.unitId == unitId && g.turno == turno) return g;
    }
    return null;
  }

  String _nombreTurno(String t) => t == 'NOCTURNO' ? 'nocturno' : 'diurno';

  /// Registrar, editar o reemplazar (mismo formulario).
  Future<void> _formulario({Guardia? editar, Guardia? reemplazar, String? unitId, String? turno}) async {
    final bid = _bid;
    if (bid == null) return;
    final base = editar;
    final nombre = TextEditingController(text: base?.nombre ?? '');
    final documento = TextEditingController(text: base?.documento ?? '');
    final telefono = TextEditingController(text: base?.telefono ?? '');
    String t = reemplazar?.turno ?? base?.turno ?? turno ?? 'DIURNO';
    String rol = reemplazar?.rol ?? base?.rol ?? 'guardia';
    final unidades = _unidades;
    String? u = reemplazar?.unitId ?? base?.unitId ?? unitId ?? (unidades.isNotEmpty ? unidades.first.id : null);
    DateTime inicio = DateTime.now();
    String? error;
    bool guardando = false;
    final titulo = reemplazar != null
        ? 'Reemplazar a ${reemplazar.nombre}'
        : (editar != null ? 'Editar guardia' : 'Registrar guardia');

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) {
          Future<void> guardar() async {
            if (nombre.text.trim().isEmpty) {
              setD(() => error = 'Escribe el nombre completo');
              return;
            }
            final unidad = u;
            if (unidad == null) {
              setD(() => error = 'El edificio no tiene unidades. Créalas en Configuración.');
              return;
            }
            // Regla: 1 diurno y 1 nocturno activos por unidad (la base también lo impide).
            if (reemplazar == null && rol == 'guardia') {
              final ocupado = _activoEn(unidad, t);
              if (ocupado != null && ocupado.id != editar?.id) {
                setD(() => error = 'Ya existe un guardia ${_nombreTurno(t)} activo para esta unidad. '
                    'Debe reemplazarlo o desactivarlo antes de registrar uno nuevo.');
                return;
              }
            }
            setD(() {
              guardando = true;
              error = null;
            });
            String? r;
            if (reemplazar != null) {
              r = await GuardiasRepo.reemplazar(reemplazar,
                  nombre: nombre.text, documento: documento.text, telefono: telefono.text, inicio: inicio);
            } else if (editar != null) {
              r = await GuardiasRepo.editar(editar,
                  nombre: nombre.text, documento: documento.text, telefono: telefono.text, turno: t, unitId: unidad);
            } else {
              r = await GuardiasRepo.registrar(
                  buildingId: bid,
                  unitId: unidad,
                  nombre: nombre.text,
                  turno: t,
                  rol: rol,
                  documento: documento.text,
                  telefono: telefono.text,
                  inicio: inicio);
            }
            if (!ctx.mounted) return;
            if (r != null) {
              final msg = r;
              setD(() {
                guardando = false;
                error = msg;
              });
              return;
            }
            if (ctx.mounted) Navigator.pop(ctx);
            if (!mounted) return;
            TopToast.show(context, reemplazar != null
                ? 'Guardia reemplazado: el nuevo empieza en cero'
                : (editar != null ? 'Datos actualizados' : 'Guardia registrado'));
            _load();
          }

          return PopScope(
            canPop: !guardando, // no se cierra mientras guarda
            child: AlertDialog(
            scrollable: true,
            title: Text(titulo, maxLines: 2, overflow: TextOverflow.ellipsis),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Edificio: $_edNombre', style: const TextStyle(fontWeight: FontWeight.w600)),
              if (reemplazar != null)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('El guardia actual queda INACTIVO y conserva su historial. '
                      'El nuevo tiene un id nuevo y empieza con horas, deuda y advertencias en cero.',
                      style: TextStyle(fontSize: 12, color: Colors.black54)),
                ),
              const SizedBox(height: 10),
              TextField(
                  controller: nombre,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Nombre completo *')),
              const SizedBox(height: 8),
              TextField(controller: documento, decoration: const InputDecoration(labelText: 'Documento de identidad')),
              const SizedBox(height: 8),
              TextField(
                  controller: telefono,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Teléfono')),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'DIURNO', label: Text('Diurno'), icon: Icon(Icons.wb_sunny_outlined)),
                  ButtonSegment(value: 'NOCTURNO', label: Text('Nocturno'), icon: Icon(Icons.nightlight_outlined)),
                ],
                selected: {t},
                onSelectionChanged: reemplazar != null ? null : (v) => setD(() => t = v.first),
              ),
              if (editar == null && reemplazar == null) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: rol,
                  decoration: const InputDecoration(labelText: 'Cargo'),
                  items: const [
                    DropdownMenuItem(value: 'guardia', child: Text('Guardia')),
                    DropdownMenuItem(value: 'franquero', child: Text('Franquero (temporal)')),
                    DropdownMenuItem(value: 'supervisor', child: Text('Supervisor')),
                  ],
                  onChanged: (v) => setD(() => rol = v ?? 'guardia'),
                ),
              ],
              if (unidades.length > 1 && reemplazar == null) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: u,
                  decoration: const InputDecoration(labelText: 'Torre / dispositivo'),
                  items: [
                    for (final x in unidades)
                      DropdownMenuItem(value: x.id, child: Text(x.name, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setD(() => u = v),
                ),
              ],
              if (editar == null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event),
                  title: const Text('Fecha de inicio'),
                  subtitle: Text(DateFormat('dd/MM/yyyy').format(inicio)),
                  onTap: () async {
                    final d = await showDatePicker(
                        context: ctx,
                        initialDate: inicio,
                        firstDate: DateTime.now().subtract(const Duration(days: 60)),
                        lastDate: DateTime.now().add(const Duration(days: 60)));
                    if (d != null) setD(() => inicio = d);
                  },
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error ?? '', style: const TextStyle(color: AppColors.rojo, fontWeight: FontWeight.w600)),
                ),
            ]),
            actions: [
              TextButton(onPressed: guardando ? null : () => Navigator.pop(ctx), child: const Text('Cancelar')),
              FilledButton(
                onPressed: guardando ? null : guardar,
                child: guardando
                    ? const SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                    : const Text('Guardar'),
              ),
            ],
          ),
          );
        },
      ),
    );
  }

  Future<void> _desactivar(Guardia g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.person_off_outlined, color: AppColors.rojo, size: 36),
        title: Text('Desactivar a ${g.nombre}'),
        content: const Text('Queda INACTIVO con fecha de hoy. No se borra: conserva sus ingresos, '
            'salidas, horas y advertencias.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Desactivar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    String? r;
    await conEspera(context, () async {
      r = await GuardiasRepo.desactivar(g);
    }, mensaje: 'Guardando…', error: 'No se pudo desactivar');
    if (!mounted) return;
    final msg = r;
    if (msg != null) {
      TopToast.show(context, msg, color: AppColors.rojo, icon: Icons.error_outline);
    } else {
      TopToast.show(context, '${g.nombre} quedó inactivo');
      _load();
    }
  }

  Future<void> _historial(Guardia g) async {
    final r = _horas[g.id] ?? ResumenGuardia(g.nombre, g.id);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HistorialGuardiaScreen(
          resumen: r,
          edificio: _edNombre,
          periodo: _periodo,
          puestos: HorasPanel.nombresUnidades(),
          toleranciaMin: _puestos.isNotEmpty ? _puestos.first.toleranciaMin : AppState.instance.toleranciaMin,
          onCorregir: Sesion.esAdmin && !_sinSenal ? _corregir : null,
          cabecera: _datosGuardia(g),
        ),
      ),
    );
  }

  Widget _datosGuardia(Guardia g) {
    final c = _conteos[g.id] ?? const {};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _linea('Edificio', _edNombre),
          if (_unidades.length > 1) _linea('Torre', Estructura.nombreUnidad(g.unitId)),
          _linea('Turno', g.diurno ? 'Diurno (08:00–20:00)' : 'Nocturno (20:00–08:00)'),
          _linea('Fecha de ingreso', DateFormat('dd/MM/yyyy').format(g.inicio)),
          if (!g.activo && g.fin != null) _linea('Fecha de salida', DateFormat('dd/MM/yyyy').format(g.fin!)),
          if ((g.documento ?? '').isNotEmpty) _linea('Documento', g.documento ?? ''),
          _linea('Rondas / incidentes (mes)', '${c['Ronda'] ?? 0} / ${c['Incidente'] ?? 0}'),
        ]),
      ),
    );
  }

  /// Corrección MANUAL de un turno (solo admin): un evento nuevo con el id del
  /// turno; la última corrección reemplaza a las anteriores (no suma dos veces).
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
              onTap: anular
                  ? null
                  : () async {
                      final v = await elegir(ctx, ini);
                      if (v != null) setD(() => ini = v);
                    },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.logout, color: AppColors.rojo),
              title: const Text('Salida'),
              subtitle: Text(fin == null ? 'Sin salida (tocar para poner)' : f.format(fin!)),
              onTap: anular
                  ? null
                  : () async {
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
            TextField(controller: motivo, decoration: const InputDecoration(labelText: 'Motivo *')),
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
    final texto = motivo.text.trim();
    if (ok != true || !mounted) return false;
    await conEspera(context, () async {
      await Cloud.evento('Corrección de turno',
          guardia: t.guardia,
          edificio: t.edificio.isEmpty ? _ed : t.edificio,
          guardId: t.guardId,
          detalle: {
            'turno_ref': t.id,
            'anular': anular,
            'inicio': ini.toUtc().toIso8601String(),
            if (fin != null) 'fin': fin!.toUtc().toIso8601String(),
            'nivel': nivel,
            'motivo': texto,
          });
      await Cloud.vaciarCola();
    }, mensaje: 'Guardando corrección…', error: 'No se pudo guardar la corrección');
    if (!mounted) return false;
    TopToast.show(context, 'Corrección guardada');
    await _load();
    return true;
  }

  Future<void> _pdf(Guardia g) async {
    await conEspera(context, () async {
      final res = await Future.wait<Object>([
        GuardiasRepo.advertencias(g.id),
        Cloud.registrosGuardiasMes(_ed, _mes, guardId: g.id, completos: true),
      ]);
      await PdfExport.guardiaPdf(
        g: g,
        edificio: _edNombre,
        unidad: Estructura.nombreUnidad(g.unitId),
        periodo: _periodo,
        resumen: _horas[g.id],
        advertencias: res[0] as List<Advertencia>,
        registros: res[1] as List<Map<String, dynamic>>,
        toleranciaMin: _puestos.isNotEmpty ? _puestos.first.toleranciaMin : AppState.instance.toleranciaMin,
      );
    });
  }

  Future<void> _advertencias(Guardia g) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => AdvertenciasGuardiaScreen(guardia: g)));
    if (mounted) _load();
  }

  // ---------------------------------------------------------------------------
  // Interfaz
  // ---------------------------------------------------------------------------

  Color _colorSaldo(double h) {
    final m = (h * 60).round();
    return m > 0 ? AppColors.verde : (m < 0 ? AppColors.rojo : Colors.blueGrey);
  }

  String _sinSigno(double h) => Turnos.saldo(h).replaceFirst('+', '');

  Widget _linea(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(k, style: const TextStyle(color: Colors.black54, fontSize: 13))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
        ]),
      );

  Widget _dato(String etiqueta, String valor, Color color) => Container(
        constraints: const BoxConstraints(minWidth: 86),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(color: color.withOpacity(0.10), borderRadius: BorderRadius.circular(12)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(valor, maxLines: 1, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
          Text(etiqueta, maxLines: 1, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ]),
      );

  Widget _seccionTitulo(String t) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Text(t,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black45, letterSpacing: .8)),
      );

  Widget _tarjeta(Guardia g) {
    final r = _horas[g.id];
    final c = _conteos[g.id] ?? const {};
    final nAdv = _adv[g.id] ?? 0;
    final ingresos = r?.turnos.where((t) => t.valido).length ?? 0;
    final salidas = r?.turnos.where((t) => t.cerrado).length ?? 0;
    final horas = r?.horas ?? 0;
    final color = g.diurno ? const Color(0xFFEF8F00) : const Color(0xFF283593);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            CircleAvatar(
              backgroundColor: color.withOpacity(.12),
              child: Icon(g.diurno ? Icons.wb_sunny : Icons.nightlight_round, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(g.rol == 'guardia' ? 'GUARDIA ${g.turno}' : '${g.rol.toUpperCase()} · ${g.turno}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.black54, letterSpacing: .6)),
                Text(g.nombre,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: (g.activo ? AppColors.verde : Colors.blueGrey).withOpacity(.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.circle, size: 9, color: g.activo ? AppColors.verde : Colors.blueGrey),
                const SizedBox(width: 4),
                Text(g.activo ? 'ACTIVO' : 'INACTIVO',
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold, color: g.activo ? AppColors.verde : Colors.blueGrey)),
              ]),
            ),
            const SizedBox(width: 6),
          ]),
          const SizedBox(height: 6),
          if (_unidades.length > 1) _linea('Torre', Estructura.nombreUnidad(g.unitId)),
          _linea('Fecha de ingreso', DateFormat('dd/MM/yyyy').format(g.inicio)),
          if (!g.activo && g.fin != null) _linea('Fecha de salida', DateFormat('dd/MM/yyyy').format(g.fin!)),
          _seccionTitulo('HORAS · ${_periodo.toUpperCase()}'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _dato('Trabajadas', '${horas.toStringAsFixed(horas % 1 == 0 ? 0 : 1)} h', AppColors.azulMarino),
            _dato('Extras', _sinSigno(r?.aFavor ?? 0), AppColors.verde),
            _dato('En deuda', _sinSigno(r?.enContra ?? 0), AppColors.rojo),
            _dato('Saldo', Turnos.saldo(r?.saldo ?? 0), _colorSaldo(r?.saldo ?? 0)),
          ]),
          _seccionTitulo('REGISTROS'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _dato('Ingresos', '$ingresos', const Color(0xFF00695C)),
            _dato('Salidas', '$salidas', const Color(0xFF455A64)),
            _dato('Rondas', '${c['Ronda'] ?? 0}', const Color(0xFF6A1B9A)),
            _dato('Incidentes', '${c['Incidente'] ?? 0}', AppColors.rojo),
          ]),
          const SizedBox(height: 8),
          Material(
            color: (nAdv > 0 ? const Color(0xFFEF6C00) : Colors.blueGrey).withOpacity(.08),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _advertencias(g),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                child: Row(children: [
                  Icon(nAdv > 0 ? Icons.warning_amber : Icons.verified_outlined,
                      color: nAdv > 0 ? const Color(0xFFEF6C00) : Colors.blueGrey, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        nAdv == 0
                            ? 'Sin advertencias activas'
                            : '$nAdv advertencia${nAdv == 1 ? '' : 's'} activa${nAdv == 1 ? '' : 's'}',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  const Text('Ver', style: TextStyle(color: AppColors.azulMarino, fontWeight: FontWeight.bold)),
                  const Icon(Icons.chevron_right, color: AppColors.azulMarino),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: Wrap(children: [
                TextButton.icon(
                    onPressed: () => _historial(g),
                    icon: const Icon(Icons.history, size: 18),
                    label: const Text('Historial')),
                if (g.activo && Sesion.esAdmin)
                  TextButton.icon(
                      onPressed: () => _formulario(editar: g),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Editar')),
                TextButton.icon(
                    onPressed: () => _pdf(g),
                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: const Text('PDF')),
              ]),
            ),
            if (g.activo && Sesion.esAdmin)
              PopupMenuButton<String>(
                tooltip: 'Más acciones',
                onSelected: (v) {
                  if (v == 'reemplazar') _formulario(reemplazar: g);
                  if (v == 'desactivar') _desactivar(g);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'reemplazar',
                      child: ListTile(leading: Icon(Icons.swap_horiz), title: Text('Reemplazar guardia'))),
                  PopupMenuItem(
                      value: 'desactivar',
                      child: ListTile(
                          leading: Icon(Icons.person_off_outlined, color: AppColors.rojo), title: Text('Desactivar'))),
                ],
              ),
          ]),
        ]),
      ),
    );
  }

  Widget _vacante(Unidad u, String turno) => Card(
        color: const Color(0xFFF7F9FB),
        child: ListTile(
          leading: Icon(turno == 'DIURNO' ? Icons.wb_sunny_outlined : Icons.nightlight_outlined, color: Colors.blueGrey),
          title: Text('Sin guardia ${_nombreTurno(turno)}', style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(u.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Sesion.esAdmin
              ? FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 14)),
                  onPressed: () => _formulario(unitId: u.id, turno: turno),
                  child: const Text('Registrar'),
                )
              : null,
        ),
      );

  List<Widget> _porUnidad() {
    final unidades = _unidades;
    final out = <Widget>[];
    final vistos = <String>{};
    for (final u in unidades) {
      if (unidades.length > 1) {
        out.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
          child: Row(children: [
            const Icon(Icons.domain, color: AppColors.azulMarino, size: 20),
            const SizedBox(width: 6),
            Expanded(
              child: Text(u.name.toUpperCase(),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.azulMarino, letterSpacing: .6)),
            ),
          ]),
        ));
      }
      for (final turno in ['DIURNO', 'NOCTURNO']) {
        final g = _activoEn(u.id, turno);
        if (g != null) {
          vistos.add(g.id);
          out.add(_tarjeta(g));
        } else {
          out.add(_vacante(u, turno));
        }
      }
      // Franquero, supervisor... activos de esta unidad.
      for (final g in _guardias.where((g) => g.activo && g.unitId == u.id && !vistos.contains(g.id))) {
        vistos.add(g.id);
        out.add(_tarjeta(g));
      }
    }
    // Activos de una unidad que ya no está en la lista (no debería pasar).
    for (final g in _guardias.where((g) => g.activo && !vistos.contains(g.id))) {
      out.add(_tarjeta(g));
    }
    return out;
  }

  Widget _resumen() {
    final activos = _guardias.where((g) => g.activo).toList();
    final ids = {for (final g in activos) g.id};
    final favor = activos.where((g) => ((_horas[g.id]?.saldo ?? 0) * 60).round() > 0).length;
    final contra = activos.where((g) => ((_horas[g.id]?.saldo ?? 0) * 60).round() < 0).length;
    final adv = _adv.entries.where((e) => ids.contains(e.key)).fold<int>(0, (a, e) => a + e.value);
    return Wrap(spacing: 8, runSpacing: 8, children: [
      _dato('Activos', '${activos.length}', AppColors.azulMarino),
      _dato('Con horas a favor', '$favor', AppColors.verde),
      _dato('Con horas en deuda', '$contra', AppColors.rojo),
      _dato('Advertencias', '$adv', const Color(0xFFEF6C00)),
    ]);
  }

  Widget _noVinculado() => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Icon(Icons.link_off, size: 40, color: Color(0xFFEF6C00)),
            const SizedBox(height: 8),
            const Text('Este celular no está vinculado',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
                'Para registrar guardias por edificio y torre, vincula este celular con su código '
                'en Configuración → Vincular celular.',
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const ConfigScreen()));
                if (mounted) _load();
              },
              icon: const Icon(Icons.settings),
              label: const Text('Ir a Configuración'),
            ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final vinculado = Sesion.vinculado;
    final inactivos = _guardias.where((g) => !g.activo).toList();
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Guardias', style: TextStyle(fontSize: 17)),
          Text(_edNombre,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ]),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Actualizar', onPressed: _load),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'pdf' && _puestos.isNotEmpty) {
                conEspera(
                    context,
                    () => PdfExport.panelHoras(
                        porEdificio: {_edNombre: _puestos},
                        periodo: _periodo,
                        nota: _sinSenal
                            ? 'Sin conexion al generar: solo incluye los turnos registrados en este celular.'
                            : null));
              }
              if (v == 'archivo') {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const GuardiasAnteriorScreen()));
              }
            },
            itemBuilder: (_) => [
              if (vinculado)
                const PopupMenuItem(
                    value: 'pdf', child: ListTile(leading: Icon(Icons.picture_as_pdf), title: Text('PDF de horas del edificio'))),
              const PopupMenuItem(
                  value: 'archivo',
                  child: ListTile(leading: Icon(Icons.inventory_2_outlined), title: Text('Archivo (sistema anterior)'))),
            ],
          ),
        ],
      ),
      floatingActionButton: vinculado && Sesion.esAdmin
          ? FloatingActionButton.extended(
              backgroundColor: AppColors.azulMarino,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.person_add),
              label: const Text('Registrar guardia'),
              onPressed: () => _formulario(),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              children: [
                if (!vinculado)
                  _noVinculado()
                else ...[
                  Row(children: [
                    IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _cambiarMes(-1)),
                    Expanded(
                      child: Text(_periodo,
                          textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      onPressed: _mes.isBefore(DateTime(DateTime.now().year, DateTime.now().month))
                          ? () => _cambiarMes(1)
                          : null,
                    ),
                  ]),
                  if (_sinSenal)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 6),
                      child: Text('Sin conexión: las horas son solo de los turnos de este celular.',
                          style: TextStyle(fontSize: 12, color: Color(0xFFEF6C00))),
                    ),
                  if (_error != null)
                    Card(
                        child: ListTile(
                            leading: const Icon(Icons.error_outline, color: AppColors.rojo), title: Text(_error ?? ''))),
                  if (_cargando && _guardias.isEmpty)
                    const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                  else ...[
                    _resumen(),
                    const SizedBox(height: 6),
                    if (_unidades.isEmpty && _error == null)
                      const Card(child: ListTile(title: Text('Este edificio no tiene unidades. Créalas en Configuración.'))),
                    ..._porUnidad(),
                    if (inactivos.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: () => setState(() => _verInactivos = !_verInactivos),
                        icon: Icon(_verInactivos ? Icons.expand_less : Icons.expand_more),
                        label: Text('${_verInactivos ? 'Ocultar' : 'Ver'} inactivos (${inactivos.length})'),
                      ),
                      if (_verInactivos) ...[for (final g in inactivos) _tarjeta(g)],
                    ],
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Advertencias de UN guardia: fecha, motivo, descripción, quién la
/// registró, estado y observaciones. Se agregan y se resuelven aquí.
class AdvertenciasGuardiaScreen extends StatefulWidget {
  final Guardia guardia;
  const AdvertenciasGuardiaScreen({super.key, required this.guardia});
  @override
  State<AdvertenciasGuardiaScreen> createState() => _AdvertenciasGuardiaScreenState();
}

class _AdvertenciasGuardiaScreenState extends State<AdvertenciasGuardiaScreen> {
  List<Advertencia> _lista = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _cargando = true);
    await Cloud.vaciarCola(); // las recién agregadas sin señal
    final l = await GuardiasRepo.advertencias(widget.guardia.id);
    if (!mounted) return;
    setState(() {
      _lista = l;
      _cargando = false;
    });
  }

  Future<void> _nueva() async {
    final motivo = TextEditingController();
    final desc = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Nueva advertencia'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: motivo, decoration: const InputDecoration(labelText: 'Motivo *')),
          const SizedBox(height: 8),
          TextField(controller: desc, maxLines: 3, decoration: const InputDecoration(labelText: 'Descripción')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () {
              if (motivo.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await Cloud.advertencia(
      guardId: widget.guardia.id,
      buildingId: widget.guardia.buildingId,
      motivo: motivo.text.trim(),
      descripcion: desc.text,
      registradoPor: Sesion.esAdmin ? 'Administrador' : AppState.instance.userNombre,
    );
    if (!mounted) return;
    await _load();
  }

  Future<void> _resolver(Advertencia a) async {
    final obs = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Marcar como resuelta'),
        content: TextField(controller: obs, maxLines: 3, decoration: const InputDecoration(labelText: 'Observaciones')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Resolver')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final r = await GuardiasRepo.resolverAdvertencia(a.id, observaciones: obs.text);
    if (!mounted) return;
    if (r != null) TopToast.show(context, r, color: AppColors.rojo, icon: Icons.error_outline);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final f = DateFormat('dd/MM/yyyy HH:mm');
    return Scaffold(
      appBar: AppBar(
          title: Text('Advertencias · ${widget.guardia.nombre}', maxLines: 1, overflow: TextOverflow.ellipsis)),
      floatingActionButton: widget.guardia.activo
          ? FloatingActionButton.extended(
              backgroundColor: const Color(0xFFEF6C00),
              foregroundColor: Colors.white,
              onPressed: _nueva,
              icon: const Icon(Icons.add_alert),
              label: const Text('Nueva advertencia'),
            )
          : null,
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                children: [
                  if (_lista.isEmpty) const Card(child: ListTile(title: Text('Sin advertencias'))),
                  for (final a in _lista)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Expanded(
                              child: Text(a.motivo,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: (a.activa ? const Color(0xFFEF6C00) : AppColors.verde).withOpacity(.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(a.activa ? 'ACTIVA' : 'RESUELTA',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: a.activa ? const Color(0xFFEF6C00) : AppColors.verde)),
                            ),
                          ]),
                          const SizedBox(height: 4),
                          Text(f.format(a.fecha), style: const TextStyle(color: Colors.black54, fontSize: 12)),
                          if ((a.descripcion ?? '').isNotEmpty)
                            Padding(padding: const EdgeInsets.only(top: 6), child: Text(a.descripcion ?? '')),
                          const SizedBox(height: 6),
                          Text('Registró: ${a.registradoPor ?? '-'}', style: const TextStyle(fontSize: 12)),
                          if ((a.observaciones ?? '').isNotEmpty)
                            Text('Observaciones: ${a.observaciones}', style: const TextStyle(fontSize: 12)),
                          if (a.activa && Sesion.esAdmin)
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () => _resolver(a),
                                icon: const Icon(Icons.check_circle_outline),
                                label: const Text('Resolver'),
                              ),
                            ),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
