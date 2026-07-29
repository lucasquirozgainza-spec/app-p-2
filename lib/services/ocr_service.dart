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

  /// Numero de la tarjeta de acceso. Las tarjetas tienen 10 digitos, asi que
  /// se prioriza una secuencia de exactamente 10; si no, la mas larga.
  static Future<String?> leerNumero(String path) async {
    final texto = await leerTexto(path);
    // Unir digitos separados por espacios (a veces el OCR los parte).
    final limpio = texto.replaceAll(RegExp(r'(?<=\d)[ \-](?=\d)'), '');
    final nums = RegExp(r'\d{3,}').allMatches(limpio).map((m) => m.group(0)!).toList();
    if (nums.isEmpty) return null;
    final diez = nums.where((n) => n.length == 10).toList();
    if (diez.isNotEmpty) return diez.first;
    nums.sort((a, b) => b.length.compareTo(a.length));
    return nums.first;
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

    if (nombre != null) nombre = _limpiarNombre(nombre);
    return CarnetData(ci, (nombre != null && nombre.trim().isNotEmpty) ? nombre : null);
  }

  // Palabras que NO forman parte de un nombre (etiquetas del carnet).
  static const _stop = {
    'FECHA', 'NACIMIENTO', 'EMISION', 'EMISIÓN', 'EXPIRACION', 'EXPIRACIÓN',
    'SERIE', 'SECCION', 'SECCIÓN', 'NOMBRES', 'APELLIDOS', 'CEDULA', 'CÉDULA',
    'IDENTIDAD', 'ESTADO', 'PLURINACIONAL', 'BOLIVIA', 'FIRMA', 'TITULAR',
    'SERVICIO', 'GENERAL', 'IDENTIFICACION', 'IDENTIFICACIÓN', 'PERSONAL',
    'DOMICILIO', 'OCUPACION', 'OCUPACIÓN', 'CIVIL', 'LUGAR', 'BIO', 'NO', 'N',
    'CERTIFICA', 'IMPRESION', 'IMPRESIÓN', 'PERTENECE', 'DOCUMENTOS', 'REGISTRADOS',
  };

  /// Deja solo palabras alfabeticas del nombre, quita numeros y etiquetas.
  static String _limpiarNombre(String s) {
    final tokens = s.toUpperCase().split(RegExp(r'[^A-ZÁÉÍÓÚÑ]+')).where((w) => w.length >= 2).toList();
    final keep = <String>[];
    for (final t in tokens) {
      if (_stop.contains(t)) continue;
      keep.add(t);
      if (keep.length >= 5) break;
    }
    return _titulo(keep.join(' '));
  }

  static String? _valorLabel(List<String> lines, int i) {
    final line = lines[i];
    final idx = line.indexOf(':');
    String v = '';
    if (idx >= 0 && idx < line.length - 1) v = line.substring(idx + 1).trim();
    if (v.isEmpty && i + 1 < lines.length) v = lines[i + 1].trim();
    // Quedarse solo con la parte de letras (cortar en el primer numero).
    final soloLetras = RegExp(r'^[A-Za-zÁÉÍÓÚÑ\s]+').firstMatch(v)?.group(0)?.trim() ?? '';
    if (soloLetras.length >= 2 && !soloLetras.toUpperCase().contains('APELLIDO')) return soloLetras;
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
