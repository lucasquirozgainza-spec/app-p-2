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

  /// Devuelve un puntaje de NITIDEZ (varianza del Laplaciano). Más alto = más
  /// nítida; muy bajo = movida/borrosa/desenfocada. Corre en un isolate.
  /// Ante cualquier error devuelve un valor alto (no bloquear al guardia).
  static Future<double> nitidez(String path) async {
    try {
      return await compute(_scoreNitidez, path);
    } catch (_) {
      return 99999;
    }
  }
}

double _scoreNitidez(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return 99999;
    final decoded = img.decodeImage(f.readAsBytesSync());
    if (decoded == null) return 99999;
    // Reducir y pasar a gris para que el cálculo sea rápido.
    final g = img.grayscale(img.copyResize(decoded, width: 420));
    final w = g.width, h = g.height;
    final data = g.getBytes(order: img.ChannelOrder.rgba); // 4 bytes/píxel
    int px(int x, int y) => data[(y * w + x) * 4]; // canal rojo = luminancia
    double sum = 0, sumSq = 0;
    int n = 0;
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        // Laplaciano 4-vecinos: resalta bordes. Foto nítida => bordes fuertes.
        final lap = (4 * px(x, y) - px(x - 1, y) - px(x + 1, y) - px(x, y - 1) - px(x, y + 1)).toDouble();
        sum += lap;
        sumSq += lap * lap;
        n++;
      }
    }
    if (n == 0) return 99999;
    final mean = sum / n;
    return (sumSq / n) - (mean * mean); // varianza
  } catch (_) {
    return 99999;
  }
}

bool _bakeOrient(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return false;
    final decoded = img.decodeImage(f.readAsBytesSync());
    if (decoded == null) return false;
    // Leer la marca EXIF de orientación. 1 = derecha; 2..8 = girada o espejada.
    int orient = 1;
    try { orient = decoded.exif.imageIfd.orientation ?? 1; } catch (_) {}
    // bakeOrientation aplica la rotación/espejo EXIF a los PÍXELES y deja la
    // imagen derecha con la marca en 1 (así WhatsApp/galería la ven siempre
    // bien, sin depender de que respeten el EXIF).
    final derecha = img.bakeOrientation(decoded);
    final cambioDim = derecha.width != decoded.width || derecha.height != decoded.height;
    // Reescribir si hubo CUALQUIER orientación no-normal (incluye 180° y espejo,
    // que no cambian el tamaño) o si cambiaron las dimensiones (90/270).
    if (orient == 1 && !cambioDim) return false; // ya estaba derecha: no tocar
    f.writeAsBytesSync(img.encodeJpg(derecha, quality: 95));
    return true;
  } catch (_) {
    return false;
  }
}
