import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/device_context.dart';
import '../theme.dart';
import '../widgets/toast.dart';
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
    final ed = AppState.instance.edificioId;
    // Traer turnos activos del edificio (tolerando edificio vacío/nulo).
    final rows = await db.query('ingreso_turno',
        where: "activo=1 AND (edificio=? OR edificio IS NULL OR edificio='')",
        whereArgs: [ed], orderBy: 'id DESC');
    final list = [for (final r in rows) Map<String, dynamic>.from(r)];
    // Garantizar que el turno del operador actual de ESTE equipo aparezca
    // siempre, aunque su edificio no coincida (evita "no hay guardia activo").
    final s = AppState.instance;
    final tid = s.turnoActivoId;
    if (tid != null && !list.any((g) => g['id'] == tid)) {
      final extra = await db.query('ingreso_turno', where: 'id=?', whereArgs: [tid]);
      if (extra.isNotEmpty) {
        list.insert(0, Map<String, dynamic>.from(extra.first));
      } else if (s.userId != null) {
        // Red de seguridad: el turno está activo en este equipo pero no se
        // encontró la fila local; permitir cerrarlo con los datos del operador.
        list.insert(0, {
          'id': tid,
          'guardia_id': s.userId,
          'guardia_nombre': s.userNombre,
          'cargo': s.userCargo,
        });
      }
    }
    if (!mounted) return;
    setState(() {
      _activos = list;
      // Preseleccionar el operador actual; si no, el único activo.
      if (tid != null) {
        final match = list.where((g) => g['id'] == tid).toList();
        _sel = match.isNotEmpty ? match.first : (list.length == 1 ? list.first : null);
      } else if (list.length == 1) {
        _sel = list.first;
      }
    });
  }

  void _snack(String m) => TopToast.show(context, m, color: AppColors.rojo, icon: Icons.error_outline);

  /// El guardia DECLARA que dobla el turno (24h) o lo triplica (36h). No cierra
  /// el turno ni pide foto: solo deja registrado el nivel para que después el
  /// conteo de 12h/24h/36h sea exacto (sin adivinar por horas).
  Future<void> _doblar(int nuevoNivel) async {
    if (_sel == null) return _snack('Selecciona el guardia');
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    await db.update('ingreso_turno', {'nivel': nuevoNivel}, where: 'id=?', whereArgs: [_sel!['id']]);
    await Audit.log('DOBLAR_TURNO', 'ingreso_turno', '${_sel!['id']}', detalle: 'nivel=$nuevoNivel');
    Cloud.evento('Doblar turno',
        guardia: _sel!['guardia_nombre'] as String?,
        detalle: {'nivel': nuevoNivel, 'edificio': s.edificioId});
    if (!mounted) return;
    TopToast.show(context, 'Turno marcado como ${nuevoNivel}h', color: AppColors.verde, icon: Icons.check_circle);
    Navigator.pop(context);
  }

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
    final nivel = (_sel!['nivel'] as int?) ?? 12;
    Cloud.evento('Salida de turno',
        guardia: _sel!['guardia_nombre'] as String?,
        detalle: {
          'nivel': nivel, // turno DECLARADO por el guardia (12/24/36)
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
          if (_sel != null) ...[
            const SizedBox(height: 16),
            Builder(builder: (_) {
              final nivel = (_sel!['nivel'] as int?) ?? 12;
              return Card(
                color: const Color(0xFFF1F8E9),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.timelapse, color: Color(0xFF33691E)),
                      const SizedBox(width: 8),
                      Text('Turno actual: ${nivel}h',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    ]),
                    const SizedBox(height: 4),
                    const Text('¿El guardia se queda a doblar? Marca aquí (no cierra el turno). '
                        'Si ya se va, usa Finalizar turno abajo.',
                        style: TextStyle(fontSize: 12, color: Colors.black54)),
                    const SizedBox(height: 10),
                    Row(children: [
                      if (nivel < 24)
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
                            onPressed: _saving ? null : () => _doblar(24),
                            icon: const Icon(Icons.replay, size: 20),
                            label: const Text('Doblar a 24h'),
                          ),
                        ),
                      if (nivel < 24 && nivel < 36) const SizedBox(width: 8),
                      if (nivel < 36)
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6A1B9A)),
                            onPressed: _saving ? null : () => _doblar(36),
                            icon: const Icon(Icons.replay_circle_filled, size: 20),
                            label: const Text('Doblar a 36h'),
                          ),
                        ),
                    ]),
                  ]),
                ),
              );
            }),
          ],
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          const Text('Salida definitiva del guardia',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 8),
          PhotoField(label: 'Foto de salida', obligatoria: true, rapida: true, frontal: true, album: 'OSIRIS Turnos', onChanged: (v) => setState(() => _foto = v)),
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
