import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/estructura.dart';
import '../services/sesion.dart';
import '../services/config_sync.dart';
import '../services/device_context.dart';
import '../services/uniform_check.dart';
import '../services/notifications_service.dart';
import '../services/turnos.dart';
import '../theme.dart';
import '../widgets/toast.dart';
import '../widgets/photo_field.dart';
import '../widgets/common.dart';

/// Inicio de turno: el guardia SELECCIONA su nombre (sin escribir), toma foto
/// y agrega novedades. Pueden registrarse varios guardias.
class InicioTurnoScreen extends StatefulWidget {
  const InicioTurnoScreen({super.key});
  @override
  State<InicioTurnoScreen> createState() => _InicioTurnoScreenState();
}

class _InicioTurnoScreenState extends State<InicioTurnoScreen> {
  final _obs = TextEditingController();
  List<Map<String, dynamic>> _guardias = [];
  Map<String, dynamic>? _sel;
  String? _foto;
  bool _saving = false;
  int _fotoKey = 0;
  bool _sinUniforme = false; // el guardia declaro que no trajo uniforme
  bool _revisando = false;

  @override
  void dispose() {
    _obs.dispose();
    super.dispose();
  }
  final _ahora = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _cargarLocales();
    // Altas/bajas hechas por el admin en otros celulares: se sincronizan a la
    // base local y se recarga la lista (sin internet, queda la lista local).
    await ConfigSync.sincronizarGuardias(forzar: true);
    await _cargarLocales();
  }

  Future<void> _cargarLocales() async {
    final db = await DB.instance.database;
    // Celular vinculado: SOLO los guardias de la nube de ESTA unidad (torre).
    // Los guardias de otra torre o del sistema anterior no aparecen.
    final rows = Sesion.vinculado
        ? await db.query('usuarios',
            where: 'guard_uuid IS NOT NULL AND activo=1 AND edificio=?'
                '${Sesion.esGuardia ? ' AND unit_id=?' : ''}',
            whereArgs: [AppState.instance.edificioId, if (Sesion.esGuardia) Sesion.unitId],
            orderBy: 'turno, nombre COLLATE NOCASE')
        : await db.query('usuarios',
            where: "rol IN ('guardia','supervisor','conserje','limpieza','franquero') AND activo=1 "
                "AND (edificio=? OR edificio IS NULL OR edificio='')",
            whereArgs: [AppState.instance.edificioId],
            orderBy: 'nombre COLLATE NOCASE');
    if (!mounted) return;
    setState(() {
      _guardias = [for (final r in rows) Map<String, dynamic>.from(r)];
      // Mantener la selección si sigue existiendo.
      final selId = _sel?['id'];
      final m = _guardias.where((g) => g['id'] == selId).toList();
      _sel = m.isEmpty ? null : m.first;
    });
  }

  void _snack(String m) => TopToast.show(context, m, color: AppColors.rojo, icon: Icons.error_outline);

  /// Al tomar la foto del guardia, revisa si lleva uniforme (camisa roja o
  /// chaleco negro). Si no lo detecta, avisa y ofrece repetir o continuar.
  Future<void> _onFoto(String? path) async {
    setState(() {
      _foto = path;
      _sinUniforme = false;
      _revisando = false;
    });
    if (path == null || !AppState.instance.controlUniforme) return;
    setState(() => _revisando = true);
    UniformeResultado r;
    try {
      r = await UniformeCheck.revisar(path);
    } catch (_) {
      if (mounted && _foto == path) setState(() => _revisando = false);
      return; // si la revisión falla no se bloquea el ingreso
    }
    // Si mientras se revisaba se tomó OTRA foto, este resultado ya no vale.
    if (!mounted || _foto != path) return;
    setState(() => _revisando = false);
    if (r.ok) return; // uniforme detectado, todo bien
    await Notificaciones.mostrarAviso('Guardia sin uniforme',
        'No se detectó la camisa roja ni el chaleco negro en la foto.');
    if (!mounted) return;
    final accion = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.report_gmailerrorred, color: AppColors.rojo, size: 40),
        title: const Text('No se ve el uniforme'),
        content: const Text('La foto no muestra camisa roja ni chaleco negro. '
            '¿Quieres repetir la foto con el uniforme puesto, o registrar que no lo trajiste?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'no'),
            child: const Text('No traje uniforme', style: TextStyle(color: AppColors.rojo)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'repetir'),
            child: const Text('Repetir foto'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (accion == 'repetir') {
      // Reinicia el campo de foto para tomarla de nuevo.
      setState(() {
        _foto = null;
        _sinUniforme = false;
        _fotoKey++;
      });
    } else if (accion == 'no') {
      setState(() => _sinUniforme = true);
      _snack('Se registrará una advertencia: sin uniforme.');
    }
  }

  Future<void> _iniciar() async {
    if (_saving) return; // doble toque
    if (_sel == null) return _snack('Selecciona el guardia');
    if (_foto == null) return _snack('La foto del guardia es obligatoria');
    if (_revisando) return _snack('Espera: revisando la foto…');
    setState(() => _saving = true);
    try {
      await _registrarIngreso();
    } catch (e) {
      if (mounted) _snack('No se pudo iniciar el turno. Intenta de nuevo.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Advertencia automática en la tarjeta del guardia (celular vinculado).
  void _advertir(String? guard, String motivo, String descripcion) {
    final bid = Sesion.buildingId ?? Estructura.idEdificio(AppState.instance.edificioId);
    if (guard == null || bid == null) return;
    Cloud.advertencia(guardId: guard, buildingId: bid, motivo: motivo, descripcion: descripcion,
        registradoPor: 'Sistema (inicio de turno)');
  }

  Future<void> _registrarIngreso() async {
    final s = AppState.instance;
    final sel = _sel!;
    // Hora REAL del ingreso: la del toque (el GPS puede tardar segundos).
    final ahora = DateTime.now();
    final db = await DB.instance.database;
    // Un guardia no puede tener dos turnos abiertos (doble registro o
    // pantalla abierta dos veces): se retoma el que ya está abierto.
    final ya = await db.query('ingreso_turno',
        where: 'guardia_id=? AND activo=1', whereArgs: [sel['id']], orderBy: 'id DESC', limit: 1);
    if (ya.isNotEmpty) {
      s.setOperador(
          id: sel['id'] as int,
          nombre: '${sel['nombre'] ?? ''}',
          cargo: sel['cargo'] as String?,
          rol: sel['rol'] as String?,
          turnoId: ya.first['id'] as int,
          guard: sel['guard_uuid'] as String?);
      if (!mounted) return;
      TopToast.show(context, '${sel['nombre']} ya tiene un turno abierto',
          color: const Color(0xFFEF6C00), icon: Icons.info_outline);
      Navigator.pop(context);
      return;
    }
    // GPS, batería y modelo EN PARALELO (antes uno tras otro).
    final ctx = await Future.wait<Object?>(
        [DeviceContext.gps(), DeviceContext.bateria(), DeviceContext.dispositivo()]);
    final gps = ctx[0] as Map<String, double>?;
    final bat = ctx[1] as int?;
    final disp = ctx[2] as String;
    final id = await db.insert('ingreso_turno', {
      'guardia_id': sel['id'],
      'guardia_nombre': sel['nombre'],
      'cargo': sel['cargo'],
      'foto': _foto,
      'gps_lat': gps?['lat'],
      'gps_lng': gps?['lng'],
      'bateria': bat,
      'dispositivo': disp,
      'observaciones': _obs.text,
      'edificio': s.edificioId,
      'activo': 1,
      'created_at': ahora.toIso8601String(),
      'guard_uuid': sel['guard_uuid'],
      'unit_id': Sesion.unitId,
    });
    // El guardia que inicia turno pasa a ser el operador actual del equipo.
    final guard = sel['guard_uuid'] as String?;
    s.setOperador(
        id: sel['id'] as int,
        nombre: '${sel['nombre'] ?? ''}',
        cargo: sel['cargo'] as String?,
        rol: sel['rol'] as String?,
        turnoId: id,
        guard: guard);
    final nombre = sel['nombre'] as String?;
    // Si el guardia declaro que no trajo uniforme, se guarda una advertencia.
    if (_sinUniforme) {
      await db.insert('advertencias', {
        'guardia_nombre': nombre,
        'mensaje': 'Inició turno SIN uniforme (sin camisa roja ni chaleco negro).',
        'tipo': 'uniforme',
        'foto': _foto,
        'edificio': s.edificioId,
        'created_at': ahora.toIso8601String(),
      });
      Cloud.evento('Guardia sin uniforme', guardia: nombre); // segundo plano
      _advertir(guard, 'Sin uniforme', 'Inició turno sin camisa roja ni chaleco negro.');
    }
    // Aviso por ENTRAR TARDE respecto al horario de relevo del celular.
    final tarde = s.minutosTardeIngreso(ahora);
    // Aviso solo pasada la tolerancia del edificio (la misma de las horas).
    if (tarde != null && tarde > s.toleranciaMin) {
      final txt = tarde >= 60
          ? '${(tarde / 60).floor()} h ${tarde % 60} min tarde'
          : '$tarde min tarde';
      await db.insert('advertencias', {
        'guardia_nombre': nombre,
        'mensaje': 'Ingresó TARDE al turno ($txt respecto al horario de relevo).',
        'tipo': 'tarde',
        'foto': _foto,
        'edificio': s.edificioId,
        'created_at': ahora.toIso8601String(),
      });
      Cloud.evento('Advertencia', guardia: nombre,
          detalle: {'tipo': 'tarde', 'motivo': 'Ingresó tarde al turno ($txt)'});
      _advertir(guard, 'Llegada tarde', 'Ingresó $txt respecto al horario de relevo.');
      try {
        await Notificaciones.mostrarAviso('⚠️ Estás entrando tarde',
            'Registraste tu ingreso $txt. Se guardó una advertencia por entrar tarde al turno.');
      } catch (_) {}
      if (mounted) _snack('Advertencia: estás entrando tarde al turno ($txt).');
    }
    await Audit.log('INICIO_TURNO', 'ingreso_turno', '$id');
    // La nube pasa por la cola: sin señal se envía después, sin duplicarse.
    Cloud.evento('Ingreso de turno',
        guardia: nombre,
        guardId: guard,
        detalle: {
          'cargo': sel['cargo'],
          // Id del turno: une este ingreso con SU salida y sus correcciones.
          'turno_ref': Turnos.ref(Cloud.deviceId, id),
          'ts': ahora.toUtc().toIso8601String(),
          // Horarios de relevo de ESTE celular: las horas se calculan con el
          // horario del puesto donde marcó (bloques distintos).
          'relevos': s.horarios.join(','),
          'observaciones': _obs.text,
          'ubicacion': gps != null ? '${gps['lat']},${gps['lng']}' : '',
        });
    Cloud.heartbeat(lat: gps?['lat'], lng: gps?['lng']);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Iniciar Turno')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Selecciona tu nombre',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          if (_guardias.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No hay guardias registrados para este edificio. '
                    'Pide al administrador que los registre en el modulo Guardias.'),
              ),
            )
          else
            DropdownButtonFormField<int>(
              value: _sel?['id'] as int?,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Guardia',
                prefixIcon: Icon(Icons.person),
              ),
              items: [
                for (final g in _guardias)
                  DropdownMenuItem<int>(
                    value: g['id'] as int,
                    child: Text(
                        g['turno'] == null
                            ? '${g['nombre']}'
                            : '${g['nombre']} · ${g['turno'] == 'NOCTURNO' ? 'Nocturno' : 'Diurno'}',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) => setState(() =>
                  _sel = _guardias.firstWhere((g) => g['id'] == id)),
            ),
          const SizedBox(height: 16),
          PhotoField(key: ValueKey(_fotoKey), label: 'Foto del guardia (selfie)', obligatoria: true, frontal: true, rapida: true, album: 'OSIRIS Turnos', onChanged: _onFoto),
          if (_revisando)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Row(children: [
                SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('Revisando uniforme...'),
              ]),
            ),
          if (_sinUniforme)
            const Card(
              color: Color(0x14C62828),
              child: ListTile(
                leading: Icon(Icons.warning_amber, color: AppColors.rojo),
                title: Text('Se registrará: guardia sin uniforme'),
              ),
            ),
          if (_sel != null) LockedField(label: 'Cargo', value: _sel!['cargo']?.toString() ?? '', icon: Icons.badge_outlined),
          Row(children: [
            Expanded(child: LockedField(label: 'Fecha', value: DateFormat('dd/MM/yyyy').format(_ahora), icon: Icons.calendar_today)),
            const SizedBox(width: 10),
            Expanded(child: LockedField(label: 'Hora', value: DateFormat('HH:mm').format(_ahora), icon: Icons.access_time)),
          ]),
          TextField(controller: _obs, maxLines: 3, decoration: const InputDecoration(labelText: 'Novedades de ingreso', alignLabelWithHint: true)),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.verde),
            onPressed: _saving ? null : _iniciar,
            icon: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.play_arrow),
            label: const Text('INICIAR TURNO'),
          ),
        ],
      ),
    );
  }
}
