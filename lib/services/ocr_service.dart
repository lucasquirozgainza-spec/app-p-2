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

  /// Numero de la tarjeta de acceso. Por defecto busca [digitos]=10 digitos
  /// (configurable por edificio). Devuelve la secuencia de esa longitud; si no
  /// la encuentra, devuelve null para que se repita la foto.
  static Future<String?> leerNumero(String path, {int digitos = 10}) async {
    final texto = await leerTexto(path);
    // Unir digitos separados por espacios (a veces el OCR los parte).
    final limpio = texto.replaceAll(RegExp(r'(?<=\d)[ \-](?=\d)'), '');
    // Secuencia de exactamente [digitos] digitos aislada.
    final exacto = RegExp(r'(?<!\d)(\d{' + '$digitos' + r'})(?!\d)').firstMatch(limpio);
    if (exacto != null) return exacto.group(1);
    // Si aparece una corrida mas larga, tomar sus primeros [digitos].
    final larga = RegExp(r'\d{' + '$digitos' + r',}').firstMatch(limpio);
    if (larga != null) return larga.group(0)!.substring(0, digitos);
    return null;
  }

  /// Lee la placa de un vehiculo (Bolivia): 3-4 digitos + 3 letras, o al reves.
  static Future<String?> leerPlaca(String path) async {
    final texto = (await leerTexto(path)).toUpperCase();
    final limpio = texto.replaceAll(RegExp(r'[^A-Z0-9\n ]'), ' ');
    final p1 = RegExp(r'(\d{3,4})\s*-?\s*([A-Z]{3})').firstMatch(limpio);
    if (p1 != null) return '${p1.group(1)}${p1.group(2)}';
    final p2 = RegExp(r'([A-Z]{3})\s*-?\s*(\d{3,4})').firstMatch(limpio);
    if (p2 != null) return '${p2.group(1)}${p2.group(2)}';
    return null;
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
    // 2) Carnet nuevo:  APELLIDOS: ...   NOMBRES: ...
    //    Combinamos SIEMPRE nombres + apellidos para armar el nombre completo.
    if (nombre == null) {
      String? nom, ape;
      for (int i = 0; i < lines.length; i++) {
        final L = lines[i].toUpperCase();
        if (nom == null && L.contains('NOMBRE')) nom = _valorLabel(lines, i);
        if (ape == null && L.contains('APELLIDO')) ape = _valorLabel(lines, i);
      }
      final full = [nom, ape].where((e) => e != null && e.trim().isNotEmpty).join(' ');
      if (full.trim().isNotEmpty) nombre = full;
    }
    // 3) Carnet antiguo (reverso): tras PERTENECE A: / A NOMBRE DE: viene el nombre.
    if (nombre == null) {
      for (int i = 0; i < lines.length; i++) {
        final L = lines[i].toUpperCase();
        if (L.contains('PERTENECE') || L.contains('NOMBRE DE') || L.contains('A NOMBRE')) {
          for (int j = i; j < lines.length && j < i + 4; j++) {
            var cand = lines[j]
                .replaceAll(RegExp(r'pertenece|a\s+nombre\s+de|nombre\s+de|^A\s*:?\s*', caseSensitive: false), '')
                .trim();
            if (_pareceNombre(cand)) {
              nombre = cand;
              break;
            }
          }
          if (nombre != null) break;
        }
      }
    }
    // 4) Ultimo recurso: cualquier linea que parezca un nombre completo
    //    (2 a 4 palabras, solo letras, sin etiquetas) -> nombre y apellido.
    if (nombre == null) {
      String? mejor;
      for (final l in lines) {
        final u = l.toUpperCase().trim();
        if (RegExp(r'\d').hasMatch(u)) continue;
        if (!RegExp(r'^[A-ZÁÉÍÓÚÑ ]+$').hasMatch(u)) continue;
        final palabras = u.split(RegExp(r'\s+')).where((w) => w.length >= 2).toList();
        if (palabras.length < 2 || palabras.length > 4) continue;
        if (palabras.any((w) => _stop.contains(w))) continue;
        if (mejor == null || u.length > mejor.length) mejor = u;
      }
      if (mejor != null) nombre = mejor;
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

  /// Lee el valor de una etiqueta (NOMBRES/APELLIDOS). El valor puede estar en
  /// la misma línea (tras ':') o en la(s) siguiente(s). Devuelve hasta 3
  /// palabras alfabéticas, sin etiquetas ni números.
  // Palabras de etiqueta: al toparse con una, se corta la acumulación del valor.
  static final RegExp _corte = RegExp(
      r'APELLIDO|NOMBRE|FECHA|NACIMIENTO|SERIE|SECC|EMISI|EXPIRA|FIRMA|IDENTIDAD|CEDULA|CÉDULA|ESTADO|PLURINACIONAL|SERVICIO|DOMICILIO|LUGAR|OCUPAC|TITULAR');

  /// Lee el valor de una etiqueta (NOMBRES/APELLIDOS). El valor puede estar en
  /// la misma línea (tras ':') y/o en la(s) siguiente(s) — se acumulan hasta
  /// toparse con otra etiqueta o un número. Así no se pierde un apellido que el
  /// OCR partió en dos líneas (ej. QUIROZ / GAINZA).
  static String? _valorLabel(List<String> lines, int i) {
    String limpiar(String s) =>
        (RegExp(r'[A-Za-zÁÉÍÓÚÑ ]+').firstMatch(s)?.group(0) ?? '').trim();

    final parts = <String>[];
    final line = lines[i];
    final idx = line.indexOf(':');
    final same = (idx >= 0 && idx < line.length - 1) ? limpiar(line.substring(idx + 1)) : '';
    if (same.length >= 2) parts.add(same);

    // Acumular líneas siguientes que parezcan nombre (hasta 3), cortando en la
    // primera etiqueta o línea con dígitos.
    for (int j = i + 1; j < lines.length && j <= i + 3; j++) {
      if (RegExp(r'\d').hasMatch(lines[j])) break;
      if (_corte.hasMatch(lines[j].toUpperCase())) break;
      final cand = limpiar(lines[j]);
      if (cand.length >= 2) parts.add(cand);
    }

    final toks = parts.join(' ').toUpperCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= 2 && !_stop.contains(w))
        .toList();
    if (toks.isEmpty) return null;
    return toks.take(4).join(' ');
  }

  /// Lee un PASAPORTE por su MRZ (2 líneas al pie). Devuelve número + nombre.
  /// Línea 1: P<BOLQUIROZ<GAINZA<<LUCAS<JOSUE<<<...
  /// Línea 2: AB1234567 <número de documento al inicio>.
  static CarnetData parsePasaporte(String texto) {
    final up = texto.toUpperCase();
    String? numero;
    String? nombre;

    // Nombre por MRZ (apellidos<<nombres).
    final mrz = RegExp(r'P[<K][A-Z<]{0,3}([A-Z]+(?:<[A-Z]+)*)<<([A-Z<]+)').firstMatch(up.replaceAll(' ', ''));
    if (mrz != null) {
      final ape = mrz.group(1)!.replaceAll('<', ' ').trim();
      final nom = mrz.group(2)!.replaceAll('<', ' ').trim();
      if (ape.isNotEmpty && nom.isNotEmpty) nombre = _limpiarNombre('$nom $ape');
    }
    // Nombre por etiquetas si no hubo MRZ.
    if (nombre == null) {
      final data = parseCarnet(texto);
      nombre = data.nombre;
    }

    // Número de documento: en la 2da línea del MRZ (primeros 6-9 caracteres) o
    // una etiqueta "Pasaporte No / Passport No".
    final et = RegExp(r'(?:PASAPORTE|PASSPORT|DOCUMENT[O]?)\s*(?:N[O°º.]*|NO|#)?\s*[:.]?\s*([A-Z0-9]{6,9})').firstMatch(up);
    if (et != null) numero = et.group(1);
    if (numero == null) {
      // Buscar una corrida alfanumérica típica de pasaporte (empieza por letra).
      final m = RegExp(r'\b([A-Z]{1,2}\d{6,7})\b').firstMatch(up.replaceAll(' ', ''));
      if (m != null) numero = m.group(1);
    }
    if (numero == null) {
      // Cualquier corrida de 7-9 dígitos como respaldo.
      final m = RegExp(r'(?<!\d)(\d{7,9})(?!\d)').firstMatch(up);
      if (m != null) numero = m.group(1);
    }
    return CarnetData(numero, nombre);
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
