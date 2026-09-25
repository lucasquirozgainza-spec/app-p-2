import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/device_context.dart';
import '../services/turnos.dart';
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
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    // Turnos abiertos de guardias dados de baja o eliminados: se cierran solos
    // (quedan "sin salida" en su historial) para que un guardia nuevo no pueda
    // cerrarlos ni heredar sus horas.
    try {
      await db.rawUpdate('UPDATE ingreso_turno SET activo=0 WHERE activo=1 AND guardia_id IS NOT NULL AND '
          '(guardia_id NOT IN (SELECT id FROM usuarios) OR guardia_id IN (SELECT id FROM usuarios WHERE activo=0))');
    } catch (_) {}
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

  /// El guardia DECLARA el turno: 12 h (normal), 24 h (doblado) o 36 h
  /// (triple). No cierra el turno ni pide foto; se puede corregir.
  Future<void> _cambiarNivel(int nivel) async {
    final sel = _sel;
    if (sel == null) return _snack('Selecciona el guardia');
    if (((sel['nivel'] as int?) ?? 12) == nivel) return;
    final db = await DB.instance.database;
    await db.update('ingreso_turno', {'nivel': nivel}, where: 'id=?', whereArgs: [sel['id']]);
    await Audit.log('DOBLAR_TURNO', 'ingreso_turno', '${sel['id']}', detalle: 'nivel=$nivel');
    // Con turno_ref el cambio se aplica a ESE turno (el último cambio gana;
    // marcar 24 y luego 36 no suma dos veces).
    Cloud.evento('Doblar turno',
        guardia: sel['guardia_nombre'] as String?,
        edificio: _edificioDe(sel),
        detalle: {
          'nivel': nivel,
          'turno_ref': Turnos.ref(Cloud.deviceId, sel['id']),
          if (sel['guard_uuid'] != null) 'guard_ci': sel['guard_uuid'],
        });
    if (!mounted) return;
    setState(() => sel['nivel'] = nivel);
    TopToast.show(context, 'Turno de $nivel h registrado', color: AppColors.verde, icon: Icons.check_circle);
  }

  /// Edificio donde se ABRIÓ el turno (la salida va al mismo edificio aunque
  /// el celular haya cambiado de edificio mientras tanto).
  String _edificioDe(Map<String, dynamic> sel) {
    final e = (sel['edificio'] ?? '').toString();
    return e.isEmpty ? AppState.instance.edificioId : e;
  }

  Future<void> _finalizar() async {
    if (_saving) return; // doble toque
    if (_sel == null) return _snack('Selecciona el guardia que sale');
    if (_foto == null) return _snack('La foto de salida es obligatoria');
    setState(() => _saving = true);
    try {
      await _registrarSalida();
    } catch (e) {
      if (mounted) _snack('No se pudo finalizar el turno. Intenta de nuevo.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _registrarSalida() async {
    final s = AppState.instance;
    final sel = _sel!;
    final ahora = DateTime.now(); // hora REAL de salida
    final db = await DB.instance.database;
    // Cerrar el turno y registrar la salida JUNTOS (si la app se cierra a la
    // mitad no queda una salida con el turno abierto) y solo si seguía
    // abierto: una segunda pantalla de salida no lo cierra dos veces.
    int? id;
    await db.transaction((txn) async {
      final n = await txn.update('ingreso_turno', {'activo': 0},
          where: 'id=? AND activo=1', whereArgs: [sel['id']]);
      if (n == 0 && sel.containsKey('created_at')) return; // ya estaba cerrado
      id = await txn.insert('salida_turno', {
        'turno_id': sel['id'],
        'guardia_id': sel['guardia_id'],
        'guardia_nombre': sel['guardia_nombre'],
        'foto': _foto,
        'observaciones': _obs.text,
        'edificio': s.edificioId,
        'created_at': ahora.toIso8601String(),
        'guard_uuid': sel['guard_uuid'],
      });
    });
    if (id == null) {
      if (s.turnoActivoId == sel['id']) s.clearOperador();
      if (!mounted) return;
      _snack('Ese turno ya estaba finalizado');
      Navigator.pop(context);
      return;
    }
    await Audit.log('FIN_TURNO', 'salida_turno', '$id');
    final nivel = Turnos.nivelValido(sel['nivel']) ?? 12;
    // Se encola YA (con la hora real); el GPS solo acompaña la presencia.
    Cloud.evento('Salida de turno',
        guardia: sel['guardia_nombre'] as String?,
        edificio: _edificioDe(sel),
        detalle: {
          if (sel['guard_uuid'] != null) 'guard_ci': sel['guard_uuid'], // CI del que sale
          'nivel': nivel, // turno DECLARADO por el guardia (12/24/36)
          'turno_ref': Turnos.ref(Cloud.deviceId, sel['id']),
          'ts': ahora.toUtc().toIso8601String(),
          'observaciones': _obs.text,
        });
    () async {
      try {
        final gps = await DeviceContext.gps();
        await Cloud.heartbeat(lat: gps?['lat'], lng: gps?['lng']);
      } catch (_) {}
    }();

    // Advertencia: tarjetas de visita que NO fueron devueltas.
    final pend = await db.query('visitas',
        where: "edificio=? AND estado='dentro' AND tarjeta_devuelta=0 AND tarjeta IS NOT NULL AND tarjeta!=''",
        whereArgs: [s.edificioId]);
    if (pend.isNotEmpty) {
      final deptos = pend.map((e) => e['depto']?.toString() ?? '?').join(', ');
      await db.insert('advertencias', {
        'guardia_nombre': sel['guardia_nombre'],
        'mensaje': 'Al finalizar turno quedaron ${pend.length} tarjeta(s) sin devolver (deptos: $deptos)',
        'tipo': 'tarjeta_turno',
        'edificio': s.edificioId,
        'created_at': DateTime.now().toIso8601String(),
      });
      Cloud.evento('Advertencia', guardia: sel['guardia_nombre'] as String?, detalle: {
        'tipo': 'tarjeta_turno',
        'motivo': '${pend.length} tarjeta(s) sin devolver (deptos: $deptos)',
        if (sel['guard_uuid'] != null) 'guard_ci': sel['guard_uuid'],
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
    if (s.turnoActivoId == sel['id']) s.clearOperador();
    if (!mounted) return;
    Navigator.pop(context);
  }

  /// Tarjeta del turno: ingreso, tiempo transcurrido, tipo 12/24/36 y fin previsto.
  Widget _tarjetaTurno(Map<String, dynamic> sel) {
    final nivel = Turnos.nivelValido(sel['nivel']) ?? 12;
    final ini = DateTime.tryParse(sel['created_at']?.toString() ?? '');
    final horarios = AppState.instance.horarios;
    final hm = DateFormat('HH:mm');
    final fin = ini == null ? null : Turnos.finPrevisto(ini, nivel, horarios);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.login, size: 18, color: AppColors.verde),
            const SizedBox(width: 6),
            Text(ini == null ? 'Ingreso —' : 'Ingreso ${hm.format(ini)}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            if (ini != null)
              Expanded(
                child: Text('Lleva ${Turnos.duracion(DateTime.now().difference(ini))}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end,
                    style: const TextStyle(color: Colors.black54)),
              ),
          ]),
          const SizedBox(height: 10),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 12, label: Text('12 h')),
              ButtonSegment(value: 24, label: Text('24 h')),
              ButtonSegment(value: 36, label: Text('36 h')),
            ],
            selected: {nivel},
            onSelectionChanged: _saving ? null : (v) => _cambiarNivel(v.first),
          ),
          const SizedBox(height: 8),
          Text(
            fin == null
                ? 'Si el guardia se queda a doblar, marca 24 h o 36 h.'
                : 'Fin previsto ${DateFormat('EEE d', 'es').format(fin)} ${hm.format(fin)} · si dobla, marca 24 h o 36 h',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ]),
      ),
    );
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
            const SizedBox(height: 12),
            _tarjetaTurno(_sel!),
          ],
          const SizedBox(height: 16),
          const Text('Salida', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
