import '../db/database_helper.dart';
import 'app_state.dart';
import 'audit.dart';
import 'crypto_util.dart';

class AuthService {
  /// Verifica credenciales de administrador. Devuelve true si es admin válido.
  static Future<bool> verifyAdmin(String usuario, String password) async {
    final db = await DB.instance.database;
    final rows = await db.query('usuarios',
        where: "usuario=? AND rol='admin' AND activo=1", whereArgs: [usuario.trim()]);
    if (rows.isEmpty) return false;
    final u = rows.first;
    final ok = CryptoUtil.verify(password, u['salt'] as String, u['pass_hash'] as String);
    if (ok) {
      AppState.instance.isAdmin = true;
      await Audit.log('ADMIN_LOGIN', 'usuarios', '${u['id']}');
    }
    return ok;
  }

  /// Registra un guardia/personal (sin contraseña; no inician sesión).
  static Future<void> crearGuardia({
    required String nombre,
    required String cargo,
    required String rol,
  }) async {
    final db = await DB.instance.database;
    final salt = CryptoUtil.newSalt();
    // usuario interno único (no se usa para login de guardia)
    final usuario = 'g${DateTime.now().millisecondsSinceEpoch}';
    final id = await db.insert('usuarios', {
      'usuario': usuario,
      'nombre': nombre,
      'cargo': cargo,
      'rol': rol,
      'pass_hash': CryptoUtil.hash('sin-clave', salt),
      'salt': salt,
      'activo': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'usuarios', '$id', detalle: 'guardia=$nombre');
  }

  /// Crea un usuario administrador (con contraseña).
  static Future<void> crearAdmin({
    required String usuario,
    required String nombre,
    required String password,
  }) async {
    final db = await DB.instance.database;
    final salt = CryptoUtil.newSalt();
    final id = await db.insert('usuarios', {
      'usuario': usuario.trim(),
      'nombre': nombre,
      'cargo': 'Administrador',
      'rol': 'admin',
      'pass_hash': CryptoUtil.hash(password, salt),
      'salt': salt,
      'activo': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'usuarios', '$id', detalle: 'admin=$usuario');
  }
}
