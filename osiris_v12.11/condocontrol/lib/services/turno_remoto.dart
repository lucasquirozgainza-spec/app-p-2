import '../db/database_helper.dart';
import 'app_state.dart';
import 'audit.dart';
import 'cloud.dart';
import 'turnos.dart';

/// Turno abierto en OTRO celular del edificio (ej. Pedro entró en el Bloque B
/// y está cubriendo en el Bloque A).
class TurnoAbierto {
  final String ref, guardia, ci, bloque;
  final DateTime inicio;
  final int nivel;
  TurnoAbierto(this.ref, this.guardia, this.ci, this.bloque, this.inicio, this.nivel);
}

/// Finalizar un turno desde cualquier celular del edificio. La salida lleva el
/// MISMO turno_ref del ingreso: el turno sigue siendo del celular donde entró
/// (sus horas y relevos no cambian) y ese celular lo cierra solo al enterarse.
class TurnoRemoto {
  static String _enc(String s) => Uri.encodeComponent(s);

  /// Turnos abiertos (últimos 3 días) que empezaron en otro celular.
  static Future<List<TurnoAbierto>> abiertosEnOtros() async {
    final s = AppState.instance;
    final desde = _enc(DateTime.now().subtract(const Duration(days: 3)).toUtc().toIso8601String());
    final rows = await Cloud.leer('eventos?select=tipo,guardia,device_id,detalle,created_at'
        '&edificio=eq.${_enc(s.edificioId)}&created_at=gte.$desde'
        '&tipo=in.(%22Ingreso%20de%20turno%22,%22Salida%20de%20turno%22,%22Doblar%20turno%22)'
        '&order=created_at.asc&limit=1000');
    final ingresos = <String, Map<String, dynamic>>{};
    final cerrados = <String>{};
    final nivel = <String, int>{};
    for (final e in rows) {
      final d = e['detalle'];
      if (d is! Map) continue;
      final ref = '${d['turno_ref'] ?? ''}';
      if (ref.isEmpty) continue;
      if (e['tipo'] == 'Ingreso de turno') ingresos[ref] = e;
      if (e['tipo'] == 'Salida de turno') cerrados.add(ref);
      final n = int.tryParse('${d['nivel'] ?? ''}');
      if (n != null && e['tipo'] != 'Ingreso de turno') nivel[ref] = n;
    }
    final out = <TurnoAbierto>[];
    for (final x in ingresos.entries) {
      if (cerrados.contains(x.key)) continue;
      final e = x.value;
      if ('${e['device_id'] ?? ''}' == Cloud.deviceId) continue; // los de aquí se cierran normal
      final d = e['detalle'] as Map;
      final ini = Cloud.horaEvento(e) ?? DateTime.now();
      if (DateTime.now().difference(ini) > const Duration(hours: 48)) continue;
      out.add(TurnoAbierto(x.key, '${e['guardia'] ?? ''}', '${d['guard_ci'] ?? ''}', '${d['bloque'] ?? ''}', ini,
          nivel[x.key] ?? 12));
    }
    out.sort((a, b) => b.inicio.compareTo(a.inicio));
    return out;
  }

  /// Registra la salida de [t] desde este celular.
  static Future<void> finalizar(TurnoAbierto t, int nivel) async {
    final s = AppState.instance;
    await Cloud.evento('Salida de turno', guardia: t.guardia, detalle: {
      if (t.ci.isNotEmpty) 'guard_ci': t.ci,
      'nivel': nivel,
      'turno_ref': t.ref,
      'ts': DateTime.now().toUtc().toIso8601String(),
      'observaciones': 'Finalizó en otro celular${s.bloque.isNotEmpty ? ' (${s.bloque})' : ''}',
      'remota': true,
    });
    await Audit.log('FIN_TURNO_REMOTO', 'ingreso_turno', t.ref);
  }

  static DateTime? _ultima;

  /// En el latido: si un turno abierto en ESTE celular se finalizó desde otro,
  /// se cierra aquí también (así el siguiente guardia puede entrar). true si cerró alguno.
  static Future<bool> aplicarSalidasRemotas() async {
    final s = AppState.instance;
    if (s.soloLocal) return false;
    final ahora = DateTime.now();
    if (_ultima != null && ahora.difference(_ultima!) < const Duration(minutes: 2)) return false;
    _ultima = ahora;
    try {
      final db = await DB.instance.database;
      final activos = await db.query('ingreso_turno', columns: ['id', 'guardia_id', 'guardia_nombre', 'guard_uuid'],
          where: 'activo=1');
      if (activos.isEmpty) return false;
      final porRef = {for (final r in activos) Turnos.ref(Cloud.deviceId, r['id']): r};
      final lista = porRef.keys.map((r) => '%22${_enc(r)}%22').join(',');
      final rows = await Cloud.leer('eventos?select=detalle,created_at&tipo=eq.${_enc('Salida de turno')}'
          '&detalle->>turno_ref=in.($lista)&limit=50');
      bool cambio = false;
      for (final e in rows) {
        final d = e['detalle'];
        if (d is! Map) continue;
        final r = porRef[d['turno_ref']];
        if (r == null) continue;
        final cuando = Cloud.horaEvento(e) ?? ahora;
        await db.transaction((txn) async {
          final n = await txn.update('ingreso_turno', {'activo': 0}, where: 'id=? AND activo=1', whereArgs: [r['id']]);
          if (n == 0) return;
          await txn.insert('salida_turno', {
            'turno_id': r['id'],
            'guardia_id': r['guardia_id'],
            'guardia_nombre': r['guardia_nombre'],
            'observaciones': '${d['observaciones'] ?? 'Finalizó en otro celular'}',
            'edificio': s.edificioId,
            'created_at': cuando.toIso8601String(),
            'guard_uuid': r['guard_uuid'],
          });
        });
        if (s.turnoActivoId == r['id']) s.clearOperador();
        cambio = true;
      }
      return cambio;
    } catch (_) {
      return false;
    }
  }
}
