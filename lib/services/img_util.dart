import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'gallery.dart';

/// Procesamiento de fotos, todo FUERA del disparo de la cámara:
/// - Endereza la foto (aplica la rotación EXIF a los píxeles y quita el EXIF)
///   para que WhatsApp/galería/nube la muestren igual que se tomó.
/// - Usa compresión NATIVA (rápida, poca memoria). Si falla, respaldo en Dart.
/// - Las fotos se procesan en una COLA de a una: la cámara queda libre al
///   instante y no se juntan varias fotos grandes en memoria a la vez.
class ImgUtil {
  /// Lado máximo conservado. 4000 px ≈ 12 MP en 4:3: calidad completa de la
  /// mayoría de cámaras. Solo se reduce si el sensor entrega algo más grande
  /// (ej. 50 MP), que haría lento todo sin aportar para identificación.
  static const int _ladoMax = 4000;

  static Future<void> _cola = Future<void>.value();
  static int _pendientes = 0;

  /// Cantidad de fotos que todavía se están procesando.
  static int get pendientes => _pendientes;

  /// Encola una foto recién tomada: enderezar y luego copiar a la galería.
  /// No bloquea: devuelve un Future por si alguien quiere esperarla.
  static Future<void> encolar(String path, {String? album}) {
    _pendientes++;
    final tarea = _cola.then((_) async {
      // La foto ORIGINAL queda tal cual la entregó la cámara (100 % de la
      // resolución y la calidad del sensor): ya no se re-comprime ni se achica.
      // La orientación va en el EXIF, que respetan la galería, WhatsApp, el
      // OCR y los PDF.
      _pendientes--;
      // La galería no hace falta esperarla: va aparte.
      unawaited(Gallery.guardar(path, album: album));
    });
    _cola = tarea;
    return tarea;
  }

  /// Ruta de la copia LEGIBLE de un documento (junto a la original).
  static String rutaLegible(String path) =>
      '${path.replaceFirst(RegExp(r'\.jpe?g$', caseSensitive: false), '')}_doc.jpg';

  /// La copia legible si ya existe; si no, la original.
  static Future<String> legible(String path) async {
    final d = rutaLegible(path);
    try {
      if (await File(d).exists()) return d;
    } catch (_) {}
    return path;
  }

  /// DOCUMENTOS (carnet, placa, tarjeta): arma en segundo plano una copia
  /// legible — derecha, 2400 px de lado corto, más contraste y más nitidez —
  /// SIN tocar la original (que queda como evidencia). No demora la foto.
  static Future<void> encolarDocumento(String path) {
    _pendientes++;
    final tarea = _cola.then((_) async {
      final destino = rutaLegible(path);
      final tmp = '$destino.base.jpg';
      try {
        // 1) Nativo (rápido y con poca memoria): derecha y tamaño de lectura.
        final base = await FlutterImageCompress.compressAndGetFile(
          path, tmp,
          minWidth: 2400,
          minHeight: 2400,
          quality: 98,
          keepExif: false,
          autoCorrectionAngle: true,
        );
        if (base == null) return;
        // 2) Contraste y nitidez en otro hilo (no traba la pantalla).
        final ok = await compute(_mejorarDocumento, [tmp, destino]);
        if (ok) unawaited(Gallery.guardar(destino, album: 'OSIRIS Documentos'));
      } catch (_) {
      } finally {
        await _borrar(tmp);
        _pendientes--;
      }
    });
    _cola = tarea;
    return tarea;
  }

  /// Espera a que terminen las fotos en cola (antes de compartir o subir).
  /// Tiene tope de tiempo para que nunca deje la pantalla colgada.
  static Future<void> esperarPendientes({Duration tope = const Duration(seconds: 20)}) async {
    if (_pendientes == 0) return;
    try {
      await _cola.timeout(tope);
    } catch (_) {}
  }

  /// Endereza la foto de forma NATIVA y reemplaza el archivo (escritura atómica:
  /// se escribe a un temporal y se renombra, nunca queda un archivo a medias).
  static Future<void> normalizarNativa(String path) async {
    final tmp = p.join(File(path).parent.path, 'n_${DateTime.now().microsecondsSinceEpoch}.jpg');
    try {
      if (!await File(path).exists()) return;
      final out = await FlutterImageCompress.compressAndGetFile(
        path, tmp,
        // IMPORTANTE: el plugin por defecto reduce a 1920x1080. Con _ladoMax
        // se conserva la resolución completa de la foto.
        minWidth: _ladoMax,
        minHeight: _ladoMax,
        quality: 92,               // visualmente igual al original, archivo menor
        keepExif: false,           // la orientación queda "quemada" en los píxeles
        autoCorrectionAngle: true, // aplica la rotación EXIF
      );
      if (out != null && await File(out.path).length() > 0) {
        await File(out.path).rename(path);
      } else {
        await _borrar(tmp);
        await compute(_bakeOrient, path);
      }
    } catch (_) {
      // Memoria llena o formato raro: el temporal no debe quedar ocupando
      // espacio, y el original sigue intacto.
      await _borrar(tmp);
      try { await compute(_bakeOrient, path); } catch (_) {}
    }
  }

  static Future<void> _borrar(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Copia para la NUBE (verla desde otros celulares): 1920 px y buena
  /// calidad, para que se lean placas, documentos y detalles. Nativa.
  static Future<Uint8List?> miniaturaNube(String path) async {
    try {
      final b = await FlutterImageCompress.compressWithFile(
        path,
        minWidth: 1920,
        minHeight: 1920,
        quality: 82,
        keepExif: false,
        autoCorrectionAngle: true,
      );
      if (b != null && b.isNotEmpty) return b;
    } catch (_) {}
    return null;
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
    int orient = 1;
    try { orient = decoded.exif.imageIfd.orientation ?? 1; } catch (_) {}
    final derecha = img.bakeOrientation(decoded);
    final cambioDim = derecha.width != decoded.width || derecha.height != decoded.height;
    if (orient == 1 && !cambioDim) return false; // ya estaba derecha
    // Temporal + renombrar: si el almacenamiento se llena a la mitad, el
    // original (única copia de la foto) no queda cortado.
    final tmp = File('${f.path}.tmp');
    try {
      tmp.writeAsBytesSync(img.encodeJpg(derecha, quality: 92), flush: true);
      tmp.renameSync(f.path);
    } catch (_) {
      try { if (tmp.existsSync()) tmp.deleteSync(); } catch (_) {}
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Mejora para LEER documentos: estira los niveles (el papel se ve blanco y
/// la tinta oscura) y aplica un enfoque suave. [a] = [origen, destino].
bool _mejorarDocumento(List<String> a) {
  try {
    final im = img.decodeJpg(File(a[0]).readAsBytesSync());
    if (im == null) return false;
    // Histograma de luminancia para hallar el 1 % más oscuro y más claro.
    final hist = List<int>.filled(256, 0);
    for (final p in im) {
      final l = img.getLuminanceRgb(p.r, p.g, p.b).round().clamp(0, 255);
      hist[l]++;
    }
    final total = im.width * im.height;
    int acum = 0, lo = 0, hi = 255;
    for (int i = 0; i < 256; i++) {
      acum += hist[i];
      if (acum >= total * 0.01) {
        lo = i;
        break;
      }
    }
    acum = 0;
    for (int i = 255; i >= 0; i--) {
      acum += hist[i];
      if (acum >= total * 0.01) {
        hi = i;
        break;
      }
    }
    if (hi - lo >= 20) {
      final f = 255.0 / (hi - lo);
      for (final p in im) {
        p.r = ((p.r - lo) * f).clamp(0, 255);
        p.g = ((p.g - lo) * f).clamp(0, 255);
        p.b = ((p.b - lo) * f).clamp(0, 255);
      }
    }
    // Enfoque suave (bordes de letras y números más definidos).
    final nitida = img.convolution(im, filter: [0, -1, 0, -1, 5, -1, 0, -1, 0], amount: 0.6);
    final tmp = File('${a[1]}.tmp');
    tmp.writeAsBytesSync(img.encodeJpg(nitida, quality: 95), flush: true);
    tmp.renameSync(a[1]);
    return true;
  } catch (_) {
    return false;
  }
}
