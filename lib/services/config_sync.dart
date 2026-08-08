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
