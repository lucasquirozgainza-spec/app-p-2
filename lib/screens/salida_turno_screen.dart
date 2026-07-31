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

/// Salida de turno: se selecciona el guardia que está saliendo (de los que
/// tienen turno activo), foto obligatoria y novedades.
class SalidaTurnoScreen extends StatefulWidget {
  const SalidaTurnoScreen({super.key});
  @override
  State<SalidaTurnoScreen> createState() => _SalidaTurnoScreenState();
}

class _SalidaTurnoScreenState extends State<SalidaTurnoScreen> {
  final _obs = TextEditingController();
  List<Map<String, dynamic>> _activos = [];
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
    final rows = await db.query('ingreso_turno',
        where: 'edificio=? AND activo=1',
        whereArgs: [AppState.instance.edificioId], orderBy: 'id DESC');
    if (!mounted) return;
    setState(() {
      _activos = rows;
      if (rows.length == 1) _sel = rows.first;
    });
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: AppColors.rojo));

  Future<void> _finalizar() async {
    if (_sel == null) return _snack('Selecciona el guardia que sale');
    if (_foto == null) return _snack('La foto de salida es obligatoria');
    setState(() => _saving = true);
    final s = AppState.instance;
    final gps = await DeviceContext.gps();
    final db = await DB.instance.database;
    final id = await db.insert('salida_turno', {
      'turno_id': _sel!['id'],
      'guardia_id': _sel!['guardia_id'],
      'guardia_nombre': _sel!['guardia_nombre'],
      'foto': _foto,
      'observaciones': _obs.text,
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.update('ingreso_turno', {'activo': 0}, where: 'id=?', whereArgs: [_sel!['id']]);
    await Audit.log('FIN_TURNO', 'salida_turno', '$id');
    Cloud.evento('Salida de turno',
        guardia: _sel!['guardia_nombre'] as String?,
        detalle: {
          'observaciones': _obs.text,
          'ubicacion': gps != null ? '${gps['lat']},${gps['lng']}' : '',
        });

    // Advertencia: tarjetas de visita que NO fueron devueltas.
    final pend = await db.query('visitas',
        where: "edificio=? AND estado='dentro' AND tarjeta_devuelta=0 AND tarjeta IS NOT NULL AND tarjeta!=''",
        whereArgs: [s.edificioId]);
    if (pend.isNotEmpty) {
      final deptos = pend.map((e) => e['depto']?.toString() ?? '?').join(', ');
      await db.insert('advertencias', {
        'guardia_nombre': _sel!['guardia_nombre'],
        'mensaje': 'Al finalizar turno quedaron ${pend.length} tarjeta(s) sin devolver (deptos: $deptos)',
        'tipo': 'tarjeta_turno',
        'edificio': s.edificioId,
        'created_at': DateTime.now().toIso8601String(),
      });
      if (mounted) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            icon: const Icon(Icons.warning_amber, color: AppColors.rojo, size: 40),
            title: const Text('Tarjetas sin devolver'),
            content: Text('Quedaron ${pend.length} tarjeta(s) de visita sin devolver '
                '(deptos: $deptos). Esta advertencia quedo registrada en el historial.'),
            actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Entendido'))],
          ),
        );
      }
    }

    // Si el que sale es el operador actual, se limpia.
    if (s.turnoActivoId == _sel!['id']) s.clearOperador();
    Cloud.heartbeat(lat: gps?['lat'], lng: gps?['lng']);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Finalizar Turno')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Selecciona el guardia que sale',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          if (_activos.isEmpty)
            const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('No hay guardias con turno activo.')))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final g in _activos)
                  ChoiceChip(
                    label: Text(g['guardia_nombre']?.toString() ?? ''),
                    selected: _sel?['id'] == g['id'],
                    onSelected: (_) => setState(() => _sel = g),
                    selectedColor: AppColors.rojo,
                    labelStyle: TextStyle(color: _sel?['id'] == g['id'] ? Colors.white : Colors.black87),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
              ],
            ),
          const SizedBox(height: 16),
          PhotoField(label: 'Foto de salida', obligatoria: true, onChanged: (v) => setState(() => _foto = v)),
          Row(children: [
            Expanded(child: LockedField(label: 'Fecha', value: DateFormat('dd/MM/yyyy').format(_ahora), icon: Icons.calendar_today)),
            const SizedBox(width: 10),
            Expanded(child: LockedField(label: 'Hora salida', value: DateFormat('HH:mm').format(_ahora), icon: Icons.access_time)),
          ]),
          TextField(controller: _obs, maxLines: 3, decoration: const InputDecoration(labelText: 'Novedades de salida', alignLabelWithHint: true)),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
            onPressed: _saving ? null : _finalizar,
            icon: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.logout),
            label: const Text('FINALIZAR TURNO'),
          ),
        ],
      ),
    );
  }
}
