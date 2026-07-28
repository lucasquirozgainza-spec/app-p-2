import '../db/database_helper.dart';
import 'app_state.dart';
import 'audit.dart';
import 'crypto_util.dart';

class AuthService {
  /// Intenta iniciar sesion. Devuelve null si ok, o un mensaje de error.
  static Future<String?> login(String usuario, String password) async {
    final db = await DB.instance.database;
    final rows = await db.query('usuarios',
        where: 'usuario = ? AND activo = 1', whereArgs: [usuario.trim()]);
    if (rows.isEmpty) return 'Usuario no encontrado o inactivo';
    final u = rows.first;
    final ok = CryptoUtil.verify(
        password, u['salt'] as String, u['pass_hash'] as String);
    if (!ok) return 'Contrasena incorrecta';

    final s = AppState.instance;
    s.userId = u['id'] as int;
    s.userNombre = u['nombre'] as String;
    s.userCargo = u['cargo'] as String?;
    s.userRol = u['rol'] as String;

    // Verificar si ya tiene un turno activo
    final turno = await db.query('ingreso_turno',
        where: 'guardia_id = ? AND activo = 1',
        whereArgs: [s.userId],
        orderBy: 'id DESC',
        limit: 1);
    s.turnoActivoId = turno.isNotEmpty ? turno.first['id'] as int : null;

    await Audit.log('LOGIN', 'usuarios', '${s.userId}');
    return null;
  }

  static Future<void> crearUsuario({
    required String usuario,
    required String nombre,
    required String cargo,
    required String rol,
    required String password,
  }) async {
    final db = await DB.instance.database;
    final salt = CryptoUtil.newSalt();
    final id = await db.insert('usuarios', {
      'usuario': usuario.trim(),
      'nombre': nombre,
      'cargo': cargo,
      'rol': rol,
      'pass_hash': CryptoUtil.hash(password, salt),
      'salt': salt,
      'activo': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'usuarios', '$id', detalle: 'usuario=$usuario rol=$rol');
  }
}
