import 'package:shared_preferences/shared_preferences.dart';
import '../db/database_helper.dart';
import 'app_state.dart';
import 'cloud.dart';

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
      final modulos = cfg['modulos']?.toString() ?? '';
      if (createdAt.isEmpty || modulos.isEmpty) return false;

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

  /// Trae los guardias que el admin registró (desde cualquier dispositivo) y
  /// los guarda LOCALMENTE en este equipo, para que aparezcan al iniciar turno
  /// aunque después se limpie la nube.
  static Future<void> sincronizarGuardias() async {
    try {
      final ed = AppState.instance.edificioId;
      final nube = await Cloud.eventos(tipo: 'Guardia', edificio: ed, limit: 300);
      if (nube.isEmpty) return;
      final db = await DB.instance.database;
      for (final e in nube) {
        final det = e['detalle'];
        final d = det is Map ? det : const {};
        final nombre = (d['nombre'] ?? e['guardia'] ?? '').toString().trim();
        if (nombre.isEmpty) continue;
        final ex = await db.query('usuarios',
            where: "nombre=? AND (edificio=? OR edificio IS NULL OR edificio='')",
            whereArgs: [nombre, ed], limit: 1);
        if (ex.isNotEmpty) continue; // ya existe: no duplicar
        await db.insert('usuarios', {
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
    } catch (_) {}
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
