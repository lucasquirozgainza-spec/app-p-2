import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Umbral de nitidez. Si la varianza del Laplaciano es MENOR a este valor,
/// la foto se considera borrosa. Súbelo para ser más exigente, bájalo si
/// rechaza fotos que en realidad están bien.
const double kBlurThreshold = 45.0;

/// Calcula la nitidez de una imagen (varianza del Laplaciano).
/// Valor alto = nítida. Valor bajo = borrosa.
Future<double> sharpnessScore(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    return await compute(_laplacianVariance, bytes);
  } catch (_) {
    // Ante cualquier error, no bloquear al usuario.
    return 9999;
  }
}

double _laplacianVariance(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return 9999;
  // Reducir para que el cálculo sea rápido en el teléfono.
  final resized = img.copyResize(decoded, width: 400);
  final g = img.grayscale(resized);
  final w = g.width, h = g.height;
  if (w < 3 || h < 3) return 9999;

  double mean = 0;
  int n = 0;
  final laps = List<double>.filled((w - 2) * (h - 2), 0);
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      final c = g.getPixel(x, y).r.toDouble();
      final up = g.getPixel(x, y - 1).r.toDouble();
      final dn = g.getPixel(x, y + 1).r.toDouble();
      final le = g.getPixel(x - 1, y).r.toDouble();
      final ri = g.getPixel(x + 1, y).r.toDouble();
      final lap = 4 * c - up - dn - le - ri;
      laps[n] = lap;
      mean += lap;
      n++;
    }
  }
  if (n == 0) return 9999;
  mean /= n;
  double variance = 0;
  for (int i = 0; i < n; i++) {
    final d = laps[i] - mean;
    variance += d * d;
  }
  return variance / n;
}
