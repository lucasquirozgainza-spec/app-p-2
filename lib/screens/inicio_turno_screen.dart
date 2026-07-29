import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/device_context.dart';
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
          PhotoField(label: 'Foto del guardia', obligatoria: true, onChanged: (v) => setState(() => _foto = v)),
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
