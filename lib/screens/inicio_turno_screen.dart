import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/device_context.dart';
import '../services/uniform_check.dart';
import '../services/notifications_service.dart';
import '../theme.dart';
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
  final _ahora = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final rows = await db.query('usuarios',
        where: "rol IN ('guardia','supervisor','conserje','limpieza','franquero') AND activo=1 "
            "AND (edificio=? OR edificio IS NULL OR edificio='')",
        whereArgs: [ed],
        orderBy: 'nombre');
    if (!mounted) return;
    setState(() => _guardias = rows);
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: AppColors.rojo));

  /// Al tomar la foto del guardia, revisa si lleva uniforme (camisa roja o
  /// chaleco negro). Si no lo detecta, avisa y ofrece repetir o continuar.
  Future<void> _onFoto(String? path) async {
    setState(() {
      _foto = path;
      _sinUniforme = false;
    });
    if (path == null || !AppState.instance.controlUniforme) return;
    setState(() => _revisando = true);
    final r = await UniformeCheck.revisar(path);
    if (!mounted) return;
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
            child: const Text('Repetir foto con uniforme'),
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
    if (_sel == null) return _snack('Selecciona el guardia');
    if (_foto == null) return _snack('La foto del guardia es obligatoria');
    setState(() => _saving = true);
    final s = AppState.instance;
    final gps = await DeviceContext.gps();
    final bat = await DeviceContext.bateria();
    final disp = await DeviceContext.dispositivo();
    final db = await DB.instance.database;
    final id = await db.insert('ingreso_turno', {
      'guardia_id': _sel!['id'],
      'guardia_nombre': _sel!['nombre'],
      'cargo': _sel!['cargo'],
      'foto': _foto,
      'gps_lat': gps?['lat'],
      'gps_lng': gps?['lng'],
      'bateria': bat,
      'dispositivo': disp,
      'observaciones': _obs.text,
      'edificio': s.edificioId,
      'activo': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    // El guardia que inicia turno pasa a ser el operador actual del equipo.
    s.setOperador(
        id: _sel!['id'] as int,
        nombre: _sel!['nombre'] as String,
        cargo: _sel!['cargo'] as String?,
        rol: _sel!['rol'] as String?,
        turnoId: id);
    // Si el guardia declaro que no trajo uniforme, se guarda una advertencia.
    if (_sinUniforme) {
      await db.insert('advertencias', {
        'guardia_nombre': _sel!['nombre'],
        'mensaje': 'Inició turno SIN uniforme (sin camisa roja ni chaleco negro).',
        'tipo': 'uniforme',
        'foto': _foto,
        'edificio': s.edificioId,
        'created_at': DateTime.now().toIso8601String(),
      });
      await Cloud.evento('Guardia sin uniforme', guardia: _sel!['nombre'] as String?);
    }
    await Audit.log('INICIO_TURNO', 'ingreso_turno', '$id');
    await Cloud.evento('Ingreso de turno',
        guardia: _sel!['nombre'] as String?,
        detalle: {'cargo': _sel!['cargo'], 'observaciones': _obs.text});
    await Cloud.heartbeat();
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
                    child: Text('${g['nombre']}  ·  ${g['cargo'] ?? ''}',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) => setState(() =>
                  _sel = _guardias.firstWhere((g) => g['id'] == id)),
            ),
          const SizedBox(height: 16),
          PhotoField(key: ValueKey(_fotoKey), label: 'Foto del guardia (selfie)', obligatoria: true, frontal: true, album: 'OSIRIS Turnos', onChanged: _onFoto),
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
