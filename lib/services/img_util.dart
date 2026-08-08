import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Corrige la orientación de una foto: algunos teléfonos guardan la imagen
/// "de lado" con una marca EXIF de rotación que no todos los visores respetan
/// (WhatsApp, galería), y la foto se ve volteada. Aquí aplicamos esa rotación
/// a los píxeles y reescribimos el archivo DERECHO. Solo reescribe si hace
/// falta (para no perder calidad en las que ya están bien). Corre en un
/// isolate para no trabar la cámara.
class ImgUtil {
  static Future<void> normalizarOrientacion(String path) async {
    try {
      await compute(_bakeOrient, path);
    } catch (_) {}
  }
}

bool _bakeOrient(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return false;
    final decoded = img.decodeImage(f.readAsBytesSync());
    if (decoded == null) return false;
    // bakeOrientation aplica la rotación EXIF a los píxeles. Si la foto ya
    // estaba derecha (sin marca de rotación) devuelve la misma imagen; solo
    // reescribimos cuando realmente cambió, para no perder calidad.
    final derecha = img.bakeOrientation(decoded);
    final cambio = derecha.width != decoded.width || derecha.height != decoded.height;
    if (!cambio) return false; // no había rotación 90/270: no tocar el original
    f.writeAsBytesSync(img.encodeJpg(derecha, quality: 95));
    return true;
  } catch (_) {
    return false;
  }
}
