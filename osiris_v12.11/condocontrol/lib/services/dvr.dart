import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

/// Lector de códigos QR (se usa para los puntos de ronda). El monitoreo de
/// cámaras/DVR fue retirado por completo de la app.
class Dvr {
  /// Lee el QR de una imagen (usa ML Kit, mismo motor del OCR).
  static Future<String?> leerQr(String path) async {
    final scanner = BarcodeScanner();
    try {
      final res = await scanner.processImage(InputImage.fromFilePath(path));
      if (res.isEmpty) return null;
      return res.first.rawValue;
    } catch (_) {
      return null;
    } finally {
      await scanner.close();
    }
  }
}
