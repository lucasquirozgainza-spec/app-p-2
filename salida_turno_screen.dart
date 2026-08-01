import '../db/database_helper.dart';
import 'app_state.dart';
import 'device_context.dart';

/// Registro de auditoria: quien creo/edito/elimino un registro y cuando.
class Audit {
  static Future<void> log(String accion, String tabla, String registroId,
      {String detalle = ''}) async {
    final db = await DB.instance.database;
    final disp = await DeviceContext.dispositivo();
    await db.insert('auditoria', {
      'usuario_id': AppState.instance.userId,
      'usuario_nombre': AppState.instance.userNombre,
      'accion': accion,
      'tabla': tabla,
      'registro_id': registroId,
      'detalle': detalle,
      'dispositivo': disp,
      'created_at': DateTime.now().toIso8601String(),
    });
  }
}
