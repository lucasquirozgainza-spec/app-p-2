import 'package:gal/gal.dart';

/// Guarda copias de las fotos en la galeria del telefono, organizadas por
/// album (Rondas, Carnet, Turnos, etc.). Nunca lanza: si falla (permiso
/// denegado, version de Android, etc.) simplemente no guarda en galeria.
class Gallery {
  static Future<void> guardar(String path, {String? album}) async {
    try {
      final nombre = (album == null || album.trim().isEmpty) ? 'OSIRIS' : album.trim();
      await Gal.putImage(path, album: nombre);
    } catch (_) {
      // Silencioso: la foto ya quedo guardada en la app aunque la galeria falle.
    }
  }
}
