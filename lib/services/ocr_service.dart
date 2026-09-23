import 'dart:io';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class CarnetData {
  final String? ci;
  final String? nombre;
  CarnetData(this.ci, this.nombre);
  bool get vacio => ci == null && nombre == null;
}

/// OCR de documentos (ML Kit, en el dispositivo, sin internet).
///
/// Cédulas bolivianas:
/// - NUEVA: frente con etiquetas APELLIDOS / NOMBRES; reverso con zona MRZ
///   (3 líneas con "<"). La MRZ es lo más confiable y se usa primero.
/// - ANTIGUA: número en el frente ("N° 1234567 LP"); el nombre en el reverso,
///   después de "...pertenecen a:" y antes de "Nacido(a) el...".
///
/// Regla de confianza: un dato solo se devuelve si pasa validaciones (formato,
/// letras, vocales, sin palabras de etiqueta). Las correcciones de caracteres
/// (0→O, 5→S, «→<<...) solo se aplican donde el tipo de dato no deja duda
/// (letras en un nombre, dígitos en un número). Si no hay seguridad, se
/// devuelve null y el guardia lo escribe.
class OcrService {
  /// Texto completo reconocido en la imagen.
  static Future<String> leerTexto(String path) async {
    final rec = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      return await _texto(rec, path);
    } finally {
      await rec.close();
    }
  }

  static Future<String> _texto(TextRecognizer rec, String path) async {
    try {
      final r = await rec.processImage(InputImage.fromFilePath(path));
      return r.text;
    } catch (_) {
      return '';
    }
  }

  /// Número de la tarjeta de acceso ([digitos] configurable por edificio).
  static Future<String?> leerNumero(String path, {int digitos = 10}) async {
    final texto = await leerTexto(path);
    final limpio = texto.replaceAll(RegExp(r'(?<=\d)[ \-](?=\d)'), '');
    final exacto = RegExp(r'(?<!\d)(\d{' '$digitos' r'})(?!\d)').firstMatch(limpio);
    if (exacto != null) return exacto.group(1);
    final larga = RegExp(r'\d{' '$digitos' r',}').firstMatch(limpio);
    if (larga != null) return larga.group(0)!.substring(0, digitos);
    return null;
  }

  /// Placa boliviana: 3-4 dígitos + 3 letras (o al revés).
  static Future<String?> leerPlaca(String path) async {
    final texto = (await leerTexto(path)).toUpperCase();
    final limpio = texto.replaceAll(RegExp(r'[^A-Z0-9\n ]'), ' ');
    final p1 = RegExp(r'(\d{3,4})\s*-?\s*([A-Z]{3})').firstMatch(limpio);
    if (p1 != null) return '${p1.group(1)}${p1.group(2)}';
    final p2 = RegExp(r'([A-Z]{3})\s*-?\s*(\d{3,4})').firstMatch(limpio);
    if (p2 != null) return '${p2.group(1)}${p2.group(2)}';
    return null;
  }

  /// Lee un carnet desde sus dos fotos (frente y reverso). Si una foto quedó
  /// girada y no se lee nada útil, reintenta rotándola (90°, 270°, 180°).
  static Future<CarnetData> leerCarnetDosLados(String frontPath, String? backPath) async {
    final rec = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final t1 = await _textoUtil(rec, frontPath);
      final t2 = (backPath != null && backPath.isNotEmpty) ? await _textoUtil(rec, backPath) : '';
      return parseDosLados(t1, t2);
    } finally {
      await rec.close();
    }
  }

  /// Combina el texto de frente y reverso respetando dónde está cada dato.
  static CarnetData parseDosLados(String frente, String reverso) {
    // Número: MRZ (cualquier lado) → etiqueta "N°" del frente → número suelto
    // del frente. Nunca un número suelto del reverso (fechas, series).
    final ci = _ciMrz(frente) ?? _ciMrz(reverso) ?? _ciEtiqueta(frente) ?? _ciSuelto(frente);
    // Nombre: MRZ → etiquetas (nuevo) → "pertenecen a:" (antiguo).
    final nombre = _nombreMrz(frente) ??
        _nombreMrz(reverso) ??
        _nombreEtiquetas(frente) ??
        _nombreAntiguo(reverso) ??
        _nombreAntiguo(frente) ??
        _nombreEtiquetas(reverso);
    return CarnetData(ci, nombre);
  }

  /// Carnet leído desde un texto ya reconocido (uno o ambos lados juntos).
  static CarnetData parseCarnet(String texto) => parseDosLados(texto, '');

  /// ¿El texto trae algo útil (número o nombre)?
  static bool _util(String t) {
    // Si el OCR ya leyó varias palabras reales, la foto está derecha: no rotar.
    if (RegExp(r'[A-Za-zÁÉÍÓÚÑáéíóúñ]{4,}').allMatches(t).length >= 8) return true;
    return _ciMrz(t) != null || _ciEtiqueta(t) != null || _ciSuelto(t) != null ||
        _nombreMrz(t) != null || _nombreEtiquetas(t) != null || _nombreAntiguo(t) != null;
  }

  /// Texto de la foto; si no sirve, prueba la foto rotada.
  static Future<String> _textoUtil(TextRecognizer rec, String path) async {
    final t = await _texto(rec, path);
    if (_util(t)) return t;
    for (final grados in const [90, 270, 180]) {
      final rot = await _rotada(path, grados);
      if (rot == null) continue;
      try {
        final tr = await _texto(rec, rot);
        if (_util(tr)) return tr;
      } finally {
        try { await File(rot).delete(); } catch (_) {}
      }
    }
    return t;
  }

  static Future<String?> _rotada(String path, int grados) async {
    try {
      final dir = await getTemporaryDirectory();
      final out = p.join(dir.path, 'ocr_${grados}_${DateTime.now().microsecondsSinceEpoch}.jpg');
      final f = await FlutterImageCompress.compressAndGetFile(path, out,
          rotate: grados, quality: 90, minWidth: 2400, minHeight: 2400);
      return f?.path;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- número CI

  /// CI desde la MRZ: "IDBOL1234567<..." / "I<BOL1234567...".
  static String? _ciMrz(String texto) {
    for (final l in texto.split('\n')) {
      final u = _normMrz(l);
      final m = RegExp(r'BOL<?([0-9O]{5,9})(?![0-9O])').firstMatch(u);
      if (m == null) continue;
      final raw = m.group(1)!;
      final digitos = raw.replaceAll(RegExp(r'[^0-9]'), '').length;
      if (digitos < raw.length - 1) continue; // demasiadas letras: no confiable
      final n = raw.replaceAll('O', '0');
      if (n.length >= 5) return n;
    }
    return null;
  }

  /// CI tras la etiqueta "N°", "No.", "Nro". Corrige O→0, I/l→1, S→5, B→8
  /// solo dentro de ese número y si casi todo ya son dígitos.
  static String? _ciEtiqueta(String texto) {
    final up = texto.toUpperCase();
    final m = RegExp(r'\bN(?:RO|O|°|º|\.)?\s*[°º\.:]?\s*([0-9OILSB]{5,11})(?![0-9])').firstMatch(up);
    if (m == null) return null;
    // Quitar letras finales pegadas (extensión LP, SC, CB, BE...).
    final raw = m.group(1)!.replaceFirst(RegExp(r'[^0-9]+$'), '');
    if (raw.length < 5 || raw.length > 9) return null;
    final digitos = raw.replaceAll(RegExp(r'[^0-9]'), '').length;
    if (digitos < raw.length * 0.75) return null;
    final n = raw
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1')
        .replaceAll('S', '5')
        .replaceAll('B', '8');
    return RegExp(r'^\d{5,9}$').hasMatch(n) ? n : null;
  }

  /// Número suelto de 6 a 8 dígitos (no parte de una fecha).
  static String? _ciSuelto(String texto) {
    final nums = RegExp(r'(?<![\d/\-.])(\d{6,8})(?![\d/\-.])')
        .allMatches(texto)
        .map((e) => e.group(1)!)
        .toList();
    if (nums.isEmpty) return null;
    nums.sort((a, b) => b.length.compareTo(a.length));
    return nums.first;
  }

  // ---------------------------------------------------------------- nombres

  /// Normaliza una línea para leer MRZ: sin espacios y con los "<" que el OCR
  /// suele confundir («, ‹, (, [, {).
  static String _normMrz(String l) => l
      .toUpperCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('«', '<<')
      .replaceAll('»', '<<')
      .replaceAll(RegExp(r'[‹(\[{]'), '<');

  /// Nombre desde la línea 3 de la MRZ: APELLIDOS<<NOMBRES<<<<.
  static String? _nombreMrz(String texto) {
    for (final l in texto.split('\n')) {
      var u = _normMrz(l);
      if (u.length < 12 || !u.contains('<<')) continue;
      if (!RegExp(r'^[A-Z0-9<]+$').hasMatch(u)) continue;
      // Pasaporte/documento: quitar prefijo "P<BOL", "I<BOL", "IDBOL".
      u = u.replaceFirst(RegExp(r'^[PI][<D][A-Z]{3}'), '');
      // Las líneas 1 y 2 tienen muchos dígitos; la de nombres, ninguno.
      final nDig = u.replaceAll(RegExp(r'[^0-9]'), '').length;
      if (nDig > 2) continue;
      u = _digitosALetras(u);
      u = u.replaceAll(RegExp(r'<+$'), '');
      u = u.replaceAll(RegExp(r'K{3,}$'), ''); // relleno "<<<" leído como KKK
      final i = u.indexOf('<<');
      if (i <= 0) continue;
      // Más de un "<<" entre palabras = lectura ambigua: no adivinar.
      if (u.indexOf('<<', i + 2) >= 0) continue;
      final ape = u.substring(0, i).split('<').where((e) => e.isNotEmpty).toList();
      final nom = u.substring(i + 2).split('<').where((e) => e.isNotEmpty).toList();
      if (ape.isEmpty || nom.isEmpty) continue;
      final r = _validar([...nom, ...ape]);
      if (r != null) return r;
    }
    return null;
  }

  /// Carnet NUEVO: etiquetas APELLIDOS (o paterno/materno) y NOMBRES.
  static String? _nombreEtiquetas(String texto) {
    final lines = _lineas(texto);
    final nombres = <String>[];
    final apellidos = <String>[];
    for (int i = 0; i < lines.length; i++) {
      final l = _letrasEnEtiqueta(lines[i]);
      if (l.contains('NOMBRE DE') || l.contains('A NOMBRE')) continue; // texto, no etiqueta
      if (RegExp(r'PADRE|MADRE|CONYUG|CÓNYUG|ESPOS').hasMatch(l)) continue; // no es el titular
      if (l.contains('APELLID') || l.contains('APELID')) {
        if (apellidos.length < 3) apellidos.addAll(_valorEtiqueta(lines, i));
      } else if (l.contains('NOMBRE') && nombres.isEmpty) {
        nombres.addAll(_valorEtiqueta(lines, i));
      }
    }
    if (nombres.isEmpty || apellidos.isEmpty) return null;
    return _validar([...nombres, ...apellidos]);
  }

  /// Carnet ANTIGUO (reverso): "...pertenecen a: NOMBRE COMPLETO Nacido el...".
  static String? _nombreAntiguo(String texto) {
    final plana = texto.toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    final fin = r'\s*,?\s*NAC[I1L|]D[OA0]';
    final pats = [
      RegExp(r'PERTENEC\w*\s*A\s*[:;.]?\s*(.{5,70}?)' + fin),
      RegExp(r'\bA\s*:\s*(.{5,70}?)' + fin),
    ];
    for (final re in pats) {
      final m = re.firstMatch(plana);
      if (m == null) continue;
      final cand = m.group(1)!;
      if (RegExp(r'\d').allMatches(cand).length > 2) continue; // basura
      final r = _validar(_tokens(cand));
      if (r != null) return r;
    }
    // Respaldo por líneas: la(s) línea(s) siguiente(s) a "pertenecen a:".
    final lines = _lineas(texto);
    for (int i = 0; i < lines.length; i++) {
      final u = lines[i].toUpperCase();
      if (!u.contains('PERTENEC')) continue;
      final tras = u.replaceFirst(RegExp(r'^.*PERTENEC\w*\s*A?\s*[:;.]?'), '');
      final toks = <String>[..._tokens(tras)];
      for (int j = i + 1; j < lines.length && j <= i + 2 && toks.length < 6; j++) {
        final lj = lines[j].toUpperCase();
        if (RegExp(r'NAC[I1L]D').hasMatch(lj)) break;
        toks.addAll(_tokens(lj));
      }
      final r = _validar(toks);
      if (r != null) return r;
    }
    return null;
  }

  // ---------------------------------------------------------------- utilidades

  static List<String> _lineas(String t) =>
      t.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  /// Línea en mayúsculas con 5→S, 0→O, 1→I (solo para RECONOCER etiquetas).
  static String _letrasEnEtiqueta(String l) =>
      l.toUpperCase().replaceAll('5', 'S').replaceAll('0', 'O').replaceAll('1', 'I');

  static final RegExp _corte = RegExp(
      r'APELLID|APELID|NOMBRE|FECHA|NACIM|SERIE|SECC|EMISI|EXPIRA|VENCE|FIRMA|IDENTIDAD|CEDULA|CÉDULA|'
      r'ESTADO|PLURINACIONAL|SERVICIO|DOMICILIO|LUGAR|OCUPAC|PROFESI|TITULAR|SEXO|NACIONAL|SURNAME|GIVEN');

  /// Valor de una etiqueta: lo que sigue a ":" en la misma línea y/o las
  /// líneas siguientes (hasta 2), cortando en otra etiqueta o en dígitos.
  static List<String> _valorEtiqueta(List<String> lines, int i) {
    final out = <String>[];
    final l = lines[i];
    final idx = l.indexOf(':');
    if (idx >= 0) out.addAll(_tokens(l.substring(idx + 1)));
    if (out.isEmpty) {
      // Etiqueta sin ":" con el valor en la misma línea ("APELLIDOS PEREZ LOPEZ").
      final lu = _letrasEnEtiqueta(l); // "APELLID0S" también cuenta
      final resto = lu.replaceFirst(
          RegExp(r'^.*?(APELLIDOS?|APELIDOS?|NOMBRES?)\b\s*(/\s*(SURNAMES?|GIVEN\s+NAMES?|NAMES?)\b)?'), '');
      if (resto != lu) out.addAll(_tokens(resto));
    }
    for (int j = i + 1; j < lines.length && j <= i + 2 && out.length < 3; j++) {
      final lj = lines[j];
      if (RegExp(r'\d{2,}').hasMatch(lj)) break;
      if (_corte.hasMatch(_letrasEnEtiqueta(lj))) break;
      out.addAll(_tokens(lj));
    }
    return out.where((t) => !_stop.contains(t)).take(3).toList();
  }

  /// Palabras de un fragmento de nombre, con correcciones seguras dentro de
  /// palabras que son casi todo letras (ej. "L0PEZ" → "LOPEZ").
  static List<String> _tokens(String s) {
    final out = <String>[];
    for (var w in s.toUpperCase().split(RegExp(r"[\s,;:./\-_'’`]+"))) {
      w = w.replaceAll('|', 'I').replaceAll('€', 'E');
      if (w.isEmpty) continue;
      final letras = RegExp(r'[A-ZÁÉÍÓÚÑÜ]').allMatches(w).length;
      final digitos = RegExp(r'\d').allMatches(w).length;
      if (digitos > 0) {
        // Solo corregir si la palabra es mayormente letras (≤1 dígito cada 4).
        if (letras < 3 || digitos * 4 > w.length) continue;
        w = _digitosALetras(w);
      }
      w = w.replaceAll(RegExp(r'[^A-ZÁÉÍÓÚÑÜ]'), '');
      if (w.isNotEmpty) out.add(w);
    }
    return out;
  }

  static String _digitosALetras(String s) => s
      .replaceAll('0', 'O')
      .replaceAll('1', 'I')
      .replaceAll('5', 'S')
      .replaceAll('8', 'B')
      .replaceAll('2', 'Z')
      .replaceAll('6', 'G')
      .replaceAll('4', 'A')
      .replaceAll('3', 'E')
      .replaceAll('7', 'T');

  // Palabras que nunca son parte de un nombre (etiquetas y textos del carnet).
  static const _stop = {
    'FECHA', 'NACIMIENTO', 'EMISION', 'EMISIÓN', 'EXPIRACION', 'EXPIRACIÓN', 'VENCIMIENTO',
    'SERIE', 'SECCION', 'SECCIÓN', 'NOMBRE', 'NOMBRES', 'APELLIDO', 'APELLIDOS', 'PATERNO', 'MATERNO',
    'CEDULA', 'CÉDULA', 'IDENTIDAD', 'ESTADO', 'PLURINACIONAL', 'BOLIVIA', 'FIRMA', 'TITULAR',
    'SERVICIO', 'GENERAL', 'IDENTIFICACION', 'IDENTIFICACIÓN', 'PERSONAL', 'SEGIP',
    'DOMICILIO', 'OCUPACION', 'OCUPACIÓN', 'PROFESION', 'PROFESIÓN', 'CIVIL', 'LUGAR', 'SEXO',
    'CERTIFICA', 'IMPRESION', 'IMPRESIÓN', 'DIGITAL', 'FOTOGRAFIA', 'FOTOGRAFÍA', 'REGISTRAN',
    'PERTENECE', 'PERTENECEN', 'DOCUMENTOS', 'REGISTRADOS', 'NACIDO', 'NACIDA', 'NACIONALIDAD',
    'BOLIVIANA', 'BOLIVIANO', 'SURNAME', 'SURNAMES', 'GIVEN', 'NAMES', 'NAME', 'DATE', 'BIRTH',
    'EXPIRY', 'DOCUMENT', 'VALIDO', 'VÁLIDO', 'HASTA', 'REPUBLICA', 'REPÚBLICA', 'QUE',
    'SOLTERO', 'SOLTERA', 'CASADO', 'CASADA', 'EL', 'EN',
  };

  // Partículas válidas de 1-3 letras en nombres/apellidos.
  static const _particulas = {'DE', 'DEL', 'LA', 'LAS', 'LOS', 'Y', 'SAN', 'VON', 'DA', 'DI'};

  /// Valida y arma el nombre. Devuelve null si no es suficientemente confiable.
  static String? _validar(List<String> toks) {
    final t = toks.where((w) => !_stop.contains(w)).toList();
    if (t.length < 2 || t.length > 7) return null;
    int fuertes = 0;
    for (final w in t) {
      if (w.length == 1 && w != 'Y') return null;
      if (w.length >= 3 && !_particulas.contains(w)) {
        if (!RegExp(r'[AEIOUÁÉÍÓÚÜY]').hasMatch(w)) return null; // sin vocal: basura
        if (RegExp(r'(.)\1\1').hasMatch(w)) return null;          // "KKK", "III"
        fuertes++;
      }
    }
    if (fuertes < 2) return null;
    final s = t.join(' ');
    if (s.length < 6 || s.length > 60) return null;
    return _titulo(s);
  }

  /// Pasaporte por su MRZ (2 líneas al pie) o por etiquetas.
  static CarnetData parsePasaporte(String texto) {
    final up = texto.toUpperCase();
    final nombre = _nombreMrz(texto) ?? _nombreEtiquetas(texto) ?? _nombreAntiguo(texto);
    String? numero;
    final et = RegExp(r'(?:PASAPORTE|PASSPORT|DOCUMENT[O]?)\s*(?:N[O°º.]*|NO|#)?\s*[:.]?\s*([A-Z0-9]{6,9})').firstMatch(up);
    if (et != null) numero = et.group(1);
    numero ??= RegExp(r'\b([A-Z]{1,2}\d{6,7})\b').firstMatch(up.replaceAll(' ', ''))?.group(1);
    numero ??= RegExp(r'(?<!\d)(\d{7,9})(?!\d)').firstMatch(up)?.group(1);
    return CarnetData(numero, nombre);
  }

  static String _titulo(String s) => s
      .split(' ')
      .where((w) => w.isNotEmpty)
      .map((w) => _particulas.contains(w) && w.length <= 3 && w != 'SAN'
          ? w.toLowerCase()
          : w[0] + w.substring(1).toLowerCase())
      .join(' ');
}
