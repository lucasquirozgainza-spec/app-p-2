import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../theme.dart';
import '../widgets/photo_field.dart';
import '../widgets/common.dart';
import 'login_screen.dart';

class SalidaTurnoScreen extends StatefulWidget {
  const SalidaTurnoScreen({super.key});
  @override
  State<SalidaTurnoScreen> createState() => _SalidaTurnoScreenState();
}

class _SalidaTurnoScreenState extends State<SalidaTurnoScreen> {
  final _obs = TextEditingController();
  String? _foto;
  bool _saving = false;
  final _ahora = DateTime.now();

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: AppColors.rojo));

  Future<void> _finalizar() async {
    if (_foto == null) return _snack('La foto de salida es obligatoria');
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    final id = await db.insert('salida_turno', {
      'turno_id': s.turnoActivoId,
      'guardia_id': s.userId,
      'guardia_nombre': s.userNombre,
      'foto': _foto,
      'observaciones': _obs.text,
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    if (s.turnoActivoId != null) {
      await db.update('ingreso_turno', {'activo': 0},
          where: 'id=?', whereArgs: [s.turnoActivoId]);
    }
    await Audit.log('FIN_TURNO', 'salida_turno', '$id');
    s.logout();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(context,
        MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Finalizar Turno')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PhotoField(
              label: 'Foto de salida',
              obligatoria: true,
              onChanged: (v) => setState(() => _foto = v)),
          LockedField(label: 'Guardia', value: s.userNombre ?? '', icon: Icons.person),
          Row(children: [
            Expanded(child: LockedField(label: 'Fecha', value: DateFormat('dd/MM/yyyy').format(_ahora), icon: Icons.calendar_today)),
            const SizedBox(width: 10),
            Expanded(child: LockedField(label: 'Hora salida', value: DateFormat('HH:mm').format(_ahora), icon: Icons.access_time)),
          ]),
          TextField(
            controller: _obs,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Novedades de salida'),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
            onPressed: _saving ? null : _finalizar,
            icon: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.logout),
            label: const Text('FINALIZAR TURNO Y SALIR'),
          ),
        ],
      ),
    );
  }
}
