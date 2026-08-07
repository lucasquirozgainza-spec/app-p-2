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
}
