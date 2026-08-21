import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Corrige la orientación de una foto: algunos teléfonos guardan la imagen
/// "de lado" con una marca EXIF de rotación que no todos los visores respetan
/// (WhatsApp, galería), y la foto se ve volteada. Aquí aplicamos esa rotación
/// a los píxeles y reescribimos el archivo DERECHO. Solo reescribe si hace
/// falta (para no perder calidad en las que ya están bien). Corre en un
/// isolate para no trabar la cámara.
class ImgUtil {
  /// Endereza la foto de forma NATIVA (rápida) y deja la imagen ya derecha, sin
  /// EXIF, para que WhatsApp/galería/nube la vean bien en cualquier visor. Es
  /// MUCHO más veloz que decodificar en Dart puro (no traba la cámara). Si el
  /// plugin nativo falla, usa el respaldo en Dart.
  static Future<void> normalizarNativa(String path) async {
    try {
      final tmp = p.join(File(path).parent.path, 'n_${DateTime.now().microsecondsSinceEpoch}.jpg');
      final out = await FlutterImageCompress.compressAndGetFile(
        path, tmp,
        quality: 95,               // casi sin pérdida (rondas nítidas)
        keepExif: false,           // quita el EXIF: la imagen queda "quemada" derecha
        autoCorrectionAngle: true, // aplica la rotación EXIF a los píxeles
      );
      if (out != null) {
        await File(out.path).rename(path); // reemplaza el original ya derecho
      } else {
        await compute(_bakeOrient, path); // respaldo Dart
      }
    } catch (_) {
      try { await compute(_bakeOrient, path); } catch (_) {}
    }
  }

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
