import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../db/database_helper.dart';
import 'app_state.dart';
import 'cloud.dart';
import 'guardias_service.dart';

/// Sincroniza la configuración (módulos) del edificio desde la nube. El admin
/// la publica con Cloud.pushConfig y los otros dispositivos del mismo edificio
/// la aplican aquí. Solo módulos (nivel edificio); los ajustes por dispositivo
/// (horarios, fotos por ronda) siguen siendo locales.
class ConfigSync {
  /// Aplica la última configuración remota si es más nueva que la aplicada.
  /// Devuelve true si cambió algo.
  static Future<bool> aplicarRemota() async {
    try {
      final ed = AppState.instance.edificioId;
      final cfg = await Cloud.ultimaConfig(ed);
      if (cfg == null) return false;
      final createdAt = cfg['created_at']?.toString() ?? '';
      // Solo se acepta un JSON de objeto válido: un valor raro guardado en la
      // nube dejaba a todos los celulares del edificio trabados al arrancar.
      final raw = cfg['modulos'];
      final modulos = raw is String ? raw : (raw is Map ? jsonEncode(raw) : '');
      if (createdAt.isEmpty || modulos.isEmpty) return false;
      try {
        if (jsonDecode(modulos) is! Map) return false;
      } catch (_) {
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      final key = 'config_at_$ed';
      if (prefs.getString(key) == createdAt) return false; // ya aplicada

      final db = await DB.instance.database;
      await db.update('edificios', {'modulos': modulos}, where: 'id=?', whereArgs: [ed]);
      await prefs.setString(key, createdAt);
      if (ed == AppState.instance.edificioId) {
        await AppState.instance.loadEdificio();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static DateTime? _ultimaSyncGuardias;
  static bool _syncGuardiasEnCurso = false;

  /// Sincroniza el personal del edificio entre celulares: altas ("Guardia") y
  /// bajas ("GuardiaBaja") que el admin hizo en cualquier equipo. Por cada
  /// nombre manda el evento MÁS RECIENTE (así se puede dar de baja y volver a
  /// registrar). Se guarda localmente para que funcione aunque se limpie la nube.
  /// [forzar]=false: como máximo cada 10 min (el latido corre cada minuto).
  static Future<void> sincronizarGuardias({bool forzar = false}) async {
    final ahora = DateTime.now();
    if (_syncGuardiasEnCurso) return;
    if (!forzar && _ultimaSyncGuardias != null &&
        ahora.difference(_ultimaSyncGuardias!) < const Duration(minutes: 10)) {
      return;
    }
    _syncGuardiasEnCurso = true;
    try {
      final ed = AppState.instance.edificioId;

      final res = await Future.wait([
        // lanzar: si UNA de las dos falla no se aplica nada (con solo las
        // altas, un guardia dado de baja volvía a aparecer).
        Cloud.eventos(tipo: 'Guardia', edificio: ed, limit: 300, lanzar: true),
        Cloud.eventos(tipo: 'GuardiaBaja', edificio: ed, limit: 300, lanzar: true),
      ]);
      _ultimaSyncGuardias = ahora;
      // Guardias con CI (su identificador): el último evento de cada CI gana.
      final porCi = <String, Map<String, dynamic>>{};
      for (final e in [...res[0], ...res[1]]) {
        final det = e['detalle'];
        final d = det is Map ? det : const {};
        final ci = GuardiasService.limpiarCi('${d['ci'] ?? ''}');
        if (ci.isEmpty) continue;
        final t = Cloud.horaEvento(e);
        if (t == null) continue;
        final prev = porCi[ci];
        if (prev == null || t.isAfter(prev['_t'] as DateTime)) porCi[ci] = {...e, '_t': t, '_det': d};
      }
      for (final e in porCi.values) {
        await GuardiasService.aplicarRemoto(ed, e['_det'] as Map, baja: e['tipo'] == 'GuardiaBaja');
      }
      // Sistema anterior (sin CI): último evento por nombre.
      final ultimo = <String, Map<String, dynamic>>{};
      for (final e in [...res[0], ...res[1]]) {
        final det = e['detalle'];
        final d = det is Map ? det : const {};
        if ('${d['ci'] ?? ''}'.trim().isNotEmpty) continue;
        final nombre = (d['nombre'] ?? '').toString().trim();
        if (nombre.isEmpty) continue;
        final k = nombre.toLowerCase();
        final prev = ultimo[k];
        // Hora real del evento (ts) y no la de subida: una baja hecha sin
        // señal y subida después no debe ganarle a una alta posterior.
        final t = Cloud.horaEvento(e);
        if (t == null) continue;
        if (prev == null || t.isAfter(prev['_t'] as DateTime)) {
          ultimo[k] = {...e, '_nombre': nombre, '_det': d, '_t': t};
        }
      }
      if (ultimo.isEmpty) return;
      final db = await DB.instance.database;
      // Nombres locales de una sola vez (antes: una consulta por evento).
      final locales = await db.query('usuarios',
          columns: ['nombre'],
          where: "edificio=? OR edificio IS NULL OR edificio=''", whereArgs: [ed]);
      final existentes = {for (final r in locales) (r['nombre'] ?? '').toString().trim().toLowerCase()};
      final batch = db.batch();
      for (final e in ultimo.values) {
        final nombre = e['_nombre'] as String;
        final k = nombre.toLowerCase();
        final d = e['_det'] as Map;
        if (e['tipo'] == 'GuardiaBaja') {
          if (existentes.contains(k)) {
            // Solo el de este edificio: los usuarios sin edificio son
            // compartidos por todos los edificios del celular.
            batch.delete('usuarios',
                where: "LOWER(nombre)=? AND rol!='admin' AND edificio=? AND guard_uuid IS NULL",
                whereArgs: [k, ed]);
          }
        } else if (!existentes.contains(k)) {
          batch.insert('usuarios', {
            'usuario': 'gsync${DateTime.now().microsecondsSinceEpoch}_${nombre.hashCode}',
            'nombre': nombre,
            'cargo': (d['cargo'] ?? '').toString(),
            'rol': (d['rol'] ?? 'guardia').toString(),
            'pass_hash': 'sync',
            'salt': 'sync',
            'activo': 1,
            'edificio': ed,
            'created_at': DateTime.now().toIso8601String(),
          });
        }
      }
      await batch.commit(noResult: true);
    } catch (_) {
    } finally {
      _syncGuardiasEnCurso = false;
    }
  }

  /// Da de baja a un guardia en ESTE celular y lo publica para los demás.
  static Future<void> darDeBaja(int id, String nombre) async {
    final db = await DB.instance.database;
    await db.delete('usuarios', where: 'id=?', whereArgs: [id]);
    Cloud.evento('GuardiaBaja', detalle: {'nombre': nombre});
  }

  /// Adopta la contraseña de admin publicada desde otro dispositivo.
  static Future<void> aplicarAdminPassRemota() async {
    try {
      final cfg = await Cloud.ultimaAdminPass();
      if (cfg == null) return;
      final createdAt = cfg['created_at']?.toString() ?? '';
      final usuario = (cfg['usuario'] ?? '').toString();
      final salt = (cfg['salt'] ?? '').toString();
      final hash = (cfg['hash'] ?? '').toString();
      if (createdAt.isEmpty || salt.isEmpty || hash.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString('adminpass_at') == createdAt) return; // ya aplicada
      final db = await DB.instance.database;
      if (usuario.isNotEmpty) {
        await db.update('usuarios', {'salt': salt, 'pass_hash': hash},
            where: "usuario=? AND rol='admin'", whereArgs: [usuario]);
      } else {
        await db.update('usuarios', {'salt': salt, 'pass_hash': hash}, where: "rol='admin'");
      }
      await prefs.setString('adminpass_at', createdAt);
    } catch (_) {}
  }
}
