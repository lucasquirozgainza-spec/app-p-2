import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// Utilidad de hashing de contrasenas (SHA-256 con salt).
class CryptoUtil {
  static final _rnd = Random.secure();

  static String newSalt() {
    final bytes = List<int>.generate(16, (_) => _rnd.nextInt(256));
    return base64Url.encode(bytes);
  }

  static String hash(String password, String salt) {
    final digest = sha256.convert(utf8.encode('$salt::$password'));
    return digest.toString();
  }

  static bool verify(String password, String salt, String expectedHash) {
    return hash(password, salt) == expectedHash;
  }
}
