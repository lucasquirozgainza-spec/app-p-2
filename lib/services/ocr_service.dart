import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Lee texto de una foto (OCR) para detectar el número de la tarjeta.
class OcrService {
  /// Devuelve la secuencia de dígitos más larga encontrada en la imagen
  /// (típicamente el número impreso en la tarjeta), o null si no encuentra.
  static Future<String?> leerNumero(String path) async {
    TextRecognizer? recognizer;
    try {
      recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final input = InputImage.fromFilePath(path);
      final result = await recognizer.processImage(input);
      // Buscar todas las secuencias de dígitos y quedarnos con la más larga.
      final matches = RegExp(r'\d{4,}').allMatches(result.text).map((m) => m.group(0)!).toList();
      if (matches.isEmpty) return null;
      matches.sort((a, b) => b.length.compareTo(a.length));
      return matches.first;
    } catch (_) {
      return null;
    } finally {
      await recognizer?.close();
    }
  }
}
