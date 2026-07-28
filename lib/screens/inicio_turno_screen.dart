import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/device_context.dart';
import '../theme.dart';
import '../widgets/photo_field.dart';
import '../widgets/common.dart';
import 'home_screen.dart';

class InicioTurnoScreen extends StatefulWidget {
  const InicioTurnoScreen({super.key});
  @override
  State<InicioTurnoScreen> createState() => _InicioTurnoScreenState();
}

class _InicioTurnoScreenState extends State<InicioTurnoScreen> {
  final _obs = TextEditingController();
  String? _foto;
  bool _saving = false;
  final _ahora = DateTime.now();

  Future<void> _iniciar() async {
    if (_foto == null) {
      _snack('La foto del guardia es obligatoria');
      return;
    }
    setState(() => _saving = true);
    final s = AppState.instance;
    final gps = await DeviceContext.gps();
    final bat = await DeviceContext.bateria();
    final disp = await DeviceContext.dispositivo();
    final db = await DB.instance.database;
    final id = await db.insert('ingreso_turno', {
      'guardia_id': s.userId,
      'guardia_nombre': s.userNombre,
      'cargo': s.userCargo,
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
    s.turnoActivoId = id;
    await Audit.log('INICIO_TURNO', 'ingreso_turno', '$id');
    if (!mounted) return;
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: AppColors.rojo));

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final fecha = DateFormat('dd/MM/yyyy').format(_ahora);
    final hora = DateFormat('HH:mm').format(_ahora);
    return Scaffold(
      appBar: AppBar(title: const Text('Registro de Inicio de Turno')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PhotoField(
            label: 'Foto del guardia',
            obligatoria: true,
            onChanged: (v) => setState(() => _foto = v),
          ),
          LockedField(label: 'Nombre', value: s.userNombre ?? '', icon: Icons.person),
          LockedField(label: 'Cargo', value: s.userCargo ?? '', icon: Icons.badge_outlined),
          Row(children: [
            Expanded(child: LockedField(label: 'Fecha', value: fecha, icon: Icons.calendar_today)),
            const SizedBox(width: 10),
            Expanded(child: LockedField(label: 'Hora', value: hora, icon: Icons.access_time)),
          ]),
          const LockedField(
              label: 'GPS / Bateria / Dispositivo',
              value: 'Se registran automaticamente',
              icon: Icons.gps_fixed),
          TextField(
            controller: _obs,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Observaciones / Novedades de ingreso',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.verde),
            onPressed: _saving ? null : _iniciar,
            icon: _saving
                ? const SizedBox(
                    height: 20, width: 20,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.play_arrow),
            label: const Text('INICIAR TURNO'),
          ),
        ],
      ),
    );
  }
}
