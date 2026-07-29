import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class CarnetData {
  final String? ci;
  final String? nombre;
  CarnetData(this.ci, this.nombre);
}

/// OCR: lee texto de fotos para detectar numero de tarjeta, CI y nombre.
class OcrService {
  /// Texto completo reconocido en la imagen.
  static Future<String> leerTexto(String path) async {
    final rec = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final r = await rec.processImage(InputImage.fromFilePath(path));
      return r.text;
    } catch (_) {
      return '';
    } finally {
      await rec.close();
    }
  }

  /// Secuencia de digitos mas larga (para el numero de tarjeta).
  static Future<String?> leerNumero(String path) async {
    final texto = await leerTexto(path);
    final matches = RegExp(r'\d{4,}').allMatches(texto).map((m) => m.group(0)!).toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) => b.length.compareTo(a.length));
    return matches.first;
  }

  /// Analiza el texto de un carnet boliviano (nuevo o antiguo) y devuelve CI y nombre.
  static CarnetData parseCarnet(String texto) {
    final up = texto.toUpperCase();
    String? ci;
    String? nombre;

    // --- CI ---
    // 1) MRZ:  I<BOL8161022<<8
    final mrz = RegExp(r'BOL[<]*?(\d{6,9})').firstMatch(up);
    if (mrz != null) ci = mrz.group(1);
    // 2) Etiqueta No / N°  8161022
    if (ci == null) {
      final m = RegExp(r'N[°O\.\s]{0,4}(\d{6,9})').firstMatch(up);
      if (m != null) ci = m.group(1);
    }
    // 3) Cualquier numero de 6-8 digitos (se descarta serie/seccion de 5)
    if (ci == null) {
      final nums = RegExp(r'(?<!\d)(\d{6,8})(?!\d)').allMatches(up).map((e) => e.group(1)!).toList();
      if (nums.isNotEmpty) {
        nums.sort((a, b) => b.length.compareTo(a.length));
        ci = nums.first;
      }
    }

    // --- Nombre ---
    // 1) MRZ:  QUIROZ<GAINZA<<LUCAS<JOSUE
    final mrzName = RegExp(r'([A-Z]+(?:<[A-Z]+)*)<<([A-Z<]+)').firstMatch(up);
    if (mrzName != null) {
      final ape = mrzName.group(1)!.replaceAll('<', ' ').trim();
      final nom = mrzName.group(2)!.replaceAll('<', ' ').trim();
      if (ape.isNotEmpty && nom.isNotEmpty) nombre = '$nom $ape';
    }
    final lines = texto.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    // 2) Carnet nuevo:  NOMBRES: ...   APELLIDOS: ...
    if (nombre == null) {
      String? nom, ape;
      for (int i = 0; i < lines.length; i++) {
        final L = lines[i].toUpperCase();
        if (L.contains('NOMBRE')) nom = _valorLabel(lines, i);
        if (L.contains('APELLIDO')) ape = _valorLabel(lines, i);
      }
      final full = [nom, ape].where((e) => e != null && e.isNotEmpty).join(' ');
      if (full.trim().isNotEmpty) nombre = full;
    }
    // 3) Carnet antiguo (reverso):  ...PERTENECE  A:  MARCELO RIVERO OCHOA
    if (nombre == null) {
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].toUpperCase().contains('PERTENECE')) {
          for (int j = i; j < lines.length && j < i + 4; j++) {
            var cand = lines[j].replaceAll(RegExp(r'^A\s*:?\s*'), '').trim();
            if (_pareceNombre(cand)) {
              nombre = cand;
              break;
            }
          }
          if (nombre != null) break;
        }
      }
    }

    if (nombre != null) nombre = _titulo(nombre.replaceAll(RegExp(r'\s+'), ' ').trim());
    return CarnetData(ci, (nombre != null && nombre.trim().isNotEmpty) ? nombre : null);
  }

  static String? _valorLabel(List<String> lines, int i) {
    final line = lines[i];
    final idx = line.indexOf(':');
    String v = '';
    if (idx >= 0 && idx < line.length - 1) v = line.substring(idx + 1).trim();
    if (v.isEmpty && i + 1 < lines.length) v = lines[i + 1].trim();
    if (RegExp(r'[A-Za-zÁÉÍÓÚÑ]{2,}').hasMatch(v) && !v.toUpperCase().contains('APELLIDO')) return v;
    return null;
  }

  static bool _pareceNombre(String s) {
    final u = s.toUpperCase();
    if (u.length < 6) return false;
    if (!RegExp(r'^[A-ZÁÉÍÓÚÑ ]+$').hasMatch(u)) return false;
    if (s.trim().split(RegExp(r'\s+')).length < 2) return false;
    const bloqueadas = ['SANTA', 'NACIDO', 'DOMICILIO', 'BOLIVIA', 'CERTIFICA', 'SERVICIO', 'IDENTIFICACION', 'PADRE', 'MADRE'];
    for (final b in bloqueadas) {
      if (u.contains(b)) return false;
    }
    return true;
  }

  static String _titulo(String s) => s
      .split(' ')
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');
}
