import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../db/database_helper.dart';

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
  /// Se lee varias veces (derecha y girada) y se vota; dentro de un bloque casi
  /// todo de dígitos se corrigen las letras que se confunden (O→0, I/l→1, S→5,
  /// B→8, Z→2, G→6). Entre candidatos, gana el impreso más grande (el número
  /// de la tarjeta suele ser lo más grande; teléfonos y series son chicos).
  static Future<String?> leerNumero(String path, {int digitos = 10}) async {
    final rec = TextRecognizer(script: TextRecognitionScript.latin);
    final votos = <String, double>{};
    final parciales = <String>{}; // números con un dígito de menos (se completan con las tarjetas conocidas)
    try {
      for (final grados in const [0, 90, 270]) {
        final String? rutaRot = grados == 0 ? path : await _rotada(path, grados);
        if (rutaRot == null) continue;
        final String ruta = rutaRot;
        try {
          final r = await rec.processImage(InputImage.fromFilePath(ruta));
          double alto = 1;
          for (final b in r.blocks) {
            for (final l in b.lines) {
              if (l.boundingBox.height > alto) alto = l.boundingBox.height;
            }
          }
          for (final b in r.blocks) {
            for (final l in b.lines) {
              for (final m in RegExp(r'(?<!\d)\d{' '${digitos - 1}' r'}(?!\d)').allMatches(l.text.replaceAll(RegExp(r'(?<=\d)[ \-.](?=\d)'), ''))) {
                parciales.add(m.group(0)!);
              }
              for (final c in candidatosTarjeta(l.text, digitos)) {
                final peso = (c.exacto ? 2.0 : 1.0) * (0.5 + l.boundingBox.height / alto);
                votos[c.numero] = (votos[c.numero] ?? 0) + peso;
              }
            }
          }
        } catch (_) {
        } finally {
          if (grados != 0) {
            try { await File(ruta).delete(); } catch (_) {}
          }
        }
        // con una lectura exacta y clara en la foto derecha, no hace falta girar
        if (votos.values.any((v) => v >= 2.5)) break;
      }
    } finally {
      await rec.close();
    }
    final l = votos.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    // Las tarjetas de un edificio se repiten: si lo leído se parece mucho a una
    // tarjeta ya registrada (un solo dígito distinto), se usa esa.
    try {
      final db = await DB.instance.database;
      final rows = await db.rawQuery(
          'SELECT DISTINCT tarjeta_num AS n FROM visitas WHERE tarjeta_num IS NOT NULL AND length(tarjeta_num) = ? ORDER BY id DESC LIMIT 800',
          [digitos]);
      final conocidas = rows.map((r) => '${r['n']}').where((x) => RegExp(r'^\d+$').hasMatch(x)).toList();
      if (l.isNotEmpty) {
        final aj = ajustarAConocida(l.first.key, conocidas);
        if (aj != null) return aj;
      } else {
        // solo se leyó parte del número: si una sola tarjeta conocida lo contiene, es esa
        final opciones = <String>{};
        for (final p in parciales) {
          for (final k in conocidas) {
            if (k.startsWith(p) || k.endsWith(p)) opciones.add(k);
          }
        }
        if (opciones.length == 1) return opciones.first;
      }
    } catch (_) {}
    return l.isEmpty ? null : l.first.key;
  }

  /// Tarjeta registrada más parecida (1 dígito distinto y sin empate).
  static String? ajustarAConocida(String n, List<String> conocidas) {
    if (conocidas.contains(n)) return n;
    String? mejor;
    var dMin = 2, empate = false;
    for (final k in conocidas.toSet()) {
      if (k.length != n.length) continue;
      var d = 0;
      for (var i = 0; i < n.length && d < 2; i++) {
        if (n[i] != k[i]) d++;
      }
      if (d < dMin) {
        dMin = d;
        mejor = k;
        empate = false;
      } else if (d == dMin) {
        empate = true;
      }
    }
    return (mejor != null && !empate && dMin <= 1) ? mejor : null;
  }

  /// Líneas con SERIE / SECCIÓN (carnet nuevo): esos números NO son el CI.
  static String _sinSerie(String texto) {
    final ls = texto.split('\n');
    final out = <String>[];
    var saltar = 0;
    for (final l in ls) {
      final u = l.toUpperCase();
      if (RegExp(r'SERIE|SECCI').hasMatch(u)) {
        saltar = RegExp(r'\d{4,}').hasMatch(u) ? 0 : 1; // el número puede venir en la línea de abajo
        continue;
      }
      if (saltar > 0) {
        saltar--;
        if (RegExp(r'^[\s\dOIl:.]+$').hasMatch(l)) continue;
      }
      out.add(l);
    }
    return out.join('\n');
  }

  static const _letraDigito = {
    'O': '0', 'o': '0', 'D': '0', 'Q': '0', 'I': '1', 'l': '1', '|': '1', '!': '1', 'i': '1',
    'S': '5', 's': '5', 'B': '8', 'Z': '2', 'z': '2', 'G': '6', 'b': '6',
  };

  /// Candidatos de número de tarjeta dentro de un texto (una línea o varias).
  static List<({String numero, bool exacto})> candidatosTarjeta(String texto, int digitos) {
    final out = <({String numero, bool exacto})>[];
    for (final linea in texto.split('\n')) {
      final l = linea.replaceAllMapped(
          RegExp(r'([0-9OIlSBZG|])[ \-.](?=[0-9OIlSBZG|])'), (m) => m.group(1)!);
      for (final bloque in l.split(RegExp(r'[^0-9A-Za-z|!]+'))) {
        if (bloque.length < digitos) continue;
        final nd = RegExp(r'\d').allMatches(bloque).length;
        if (nd < digitos - 2 || nd < bloque.length * 0.7) continue;
        final fijo = bloque.split('').map((c) => RegExp(r'\d').hasMatch(c) ? c : (_letraDigito[c] ?? '')).join();
        if (fijo.length == digitos) {
          out.add((numero: fijo, exacto: nd == digitos && bloque.length == digitos));
        } else if (fijo.length > digitos && nd == bloque.length) {
          out.add((numero: fijo.substring(0, digitos), exacto: false));
        }
      }
    }
    return out;
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
      final r = parseDosLados(t1, t2);
      if (r.ci != null) return r;
      // El N° del carnet viene impreso en ROJO: si no salió, se reintenta con
      // el canal verde de la foto, donde el rojo queda oscuro y se lee.
      for (final par in [[frontPath, t2], [backPath, t1]]) {
        final ruta = par[0];
        if (ruta == null || ruta.isEmpty) continue;
        final verde = await _canalVerde(ruta);
        if (verde == null) continue;
        try {
          final tv = await _texto(rec, verde);
          final ci = parseDosLados(tv, par[1] ?? '').ci;
          if (ci != null) return CarnetData(ci, r.nombre);
        } finally {
          try { await File(verde).delete(); } catch (_) {}
        }
      }
      return r;
    } finally {
      await rec.close();
    }
  }

  /// Combina el texto de frente y reverso respetando dónde está cada dato.
  static CarnetData parseDosLados(String frente, String reverso) {
    // Número: MRZ (cualquier lado) → etiqueta "N°" del frente → número suelto
    // del frente. Nunca un número suelto del reverso (fechas, series).
    final fr = _sinSerie(frente), rv = _sinSerie(reverso);
    final ci = _ciMrz(frente) ?? _ciMrz(reverso) ?? _ciEtiqueta(fr) ?? _ciEtiqueta(rv) ?? _ciSuelto(fr);
    // Nombre: MRZ (lo más seguro) mejorada con las etiquetas (tildes, Ñ,
    // nombres completos) → "pertenecen a:" (antiguo).
    final mrz = _nombreMrz(frente) ?? _nombreMrz(reverso);
    final et = _nombreEtiquetas(frente) ?? _nombreEtiquetas(reverso);
    final nombre = mejorNombre(mrz, et) ?? _nombreAntiguo(reverso) ?? _nombreAntiguo(frente);
    return CarnetData(ci, nombre);
  }

  static String _sinTilde(String x) {
    const de = 'ÁÉÍÓÚÜÑáéíóúüñ', a = 'AEIOUUNaeiouun';
    final b = StringBuffer();
    for (final c in x.split('')) {
      final i = de.indexOf(c);
      b.write(i >= 0 ? a[i] : c);
    }
    return b.toString().toUpperCase();
  }

  /// La MRZ no lleva tildes ni Ñ y a veces viene cortada: si las etiquetas
  /// dicen lo mismo (o lo mismo y más), se usa la versión de las etiquetas.
  static String? mejorNombre(String? mrz, String? et) {
    if (mrz == null) return et;
    if (et == null) return mrz;
    final a = _sinTilde(mrz).split(' '), b = _sinTilde(et).split(' ');
    if (a.join(' ') == b.join(' ')) return et;
    if (a.length < b.length && a.every(b.contains)) return et;
    if (a.length == b.length) {
      var ok = true;
      for (var k = 0; k < a.length; k++) {
        if (!b[k].startsWith(a[k])) ok = false;
      }
      if (ok) return et;
    }
    return mrz;
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

  /// Copia de la foto en gris tomando solo el canal verde (el texto rojo sale negro).
  static Future<String?> _canalVerde(String path) async {
    try {
      final dir = await getTemporaryDirectory();
      final out = p.join(dir.path, 'ocr_v_${DateTime.now().microsecondsSinceEpoch}.jpg');
      final ok = await compute(_verdeIsolate, [path, out]);
      return ok ? out : null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _verdeIsolate(List<String> a) async {
    final bytes = await File(a[0]).readAsBytes();
    var im = img.decodeImage(bytes);
    if (im == null) return false;
    im = img.bakeOrientation(im);
    final lado = im.width > im.height ? im.width : im.height;
    if (lado > 2400) {
      im = im.width >= im.height ? img.copyResize(im, width: 2400) : img.copyResize(im, height: 2400);
    }
    for (final px in im) {
      final g = px.g;
      px
        ..r = g
        ..b = g;
    }
    await File(a[1]).writeAsBytes(img.encodeJpg(im, quality: 92));
    return true;
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
    String? suelto;
    for (final l in texto.split('\n')) {
      final u = _normMrz(l);
      final v = _ciMrzControl(u);
      if (v != null) return v;
      if (suelto != null) continue;
      final m = RegExp(r'BOL<?([0-9O]{5,9})(?![0-9O])').firstMatch(u);
      if (m == null) continue;
      final raw = m.group(1)!;
      final digitos = raw.replaceAll(RegExp(r'[^0-9]'), '').length;
      if (digitos < raw.length - 1) continue; // demasiadas letras: no confiable
      final n = raw.replaceAll('O', '0');
      if (n.length >= 5) suelto = n;
    }
    return suelto;
  }

  static const _aDigMrz = {'O': '0', 'D': '0', 'Q': '0', 'U': '0', 'I': '1', 'L': '1', 'T': '1', 'S': '5', 'B': '8', 'Z': '2', 'G': '6', 'A': '4'};

  /// Dígito de control ICAO (pesos 7-3-1); -1 si hay un carácter inválido.
  static int _control(String campo) {
    var s = 0;
    const w = [7, 3, 1];
    for (var i = 0; i < campo.length; i++) {
      final c = campo.codeUnitAt(i);
      int v;
      if (c == 60) {
        v = 0; // '<'
      } else if (c >= 48 && c <= 57) {
        v = c - 48;
      } else if (c >= 65 && c <= 90) {
        v = c - 55;
      } else {
        return -1;
      }
      s += v * w[i % 3];
    }
    return s % 10;
  }

  /// Número de la MRZ confirmado con su dígito de control. Corrige letras
  /// confundidas y, si sigue sin cuadrar, prueba UN dígito mal leído (6↔8,
  /// 1↔7...) solo si una única corrección cuadra.
  static String? _ciMrzControl(String u) {
    final i = u.indexOf('BOL');
    if (i < 0 || u.length < i + 13) return null;
    final campo = u.substring(i + 3, i + 12), cd = u[i + 12];
    final cdS = RegExp(r'\d').hasMatch(cd) ? cd : _aDigMrz[cd];
    if (cdS == null) return null;
    final cdv = int.parse(cdS);
    final base = campo.replaceFirst(RegExp(r'<+$'), '');
    if (base.length < 5) return null;
    var letras = 0;
    final b = StringBuffer();
    for (final c in base.split('')) {
      if (RegExp(r'\d').hasMatch(c)) {
        b.write(c);
      } else {
        final d = _aDigMrz[c];
        if (d == null) return null;
        letras++;
        b.write(d);
      }
    }
    if (letras > 2) return null;
    final n = b.toString();
    if (_control(n.padRight(9, '<')) == cdv) return n;
    const vec = {'0': '86', '1': '7', '3': '8', '5': '6', '6': '58', '7': '1', '8': '063', '9': '4'};
    final ok = <String>[];
    for (var k = 0; k < n.length; k++) {
      for (final r in (vec[n[k]] ?? '').split('')) {
        if (r.isEmpty) continue;
        final v = n.substring(0, k) + r + n.substring(k + 1);
        if (_control(v.padRight(9, '<')) == cdv) ok.add(v);
      }
    }
    return ok.length == 1 ? ok.first : null;
  }

  /// CI tras la etiqueta "N°", "No.", "Nro". Corrige O→0, I/l→1, S→5, B→8
  /// solo dentro de ese número y si casi todo ya son dígitos.
  static String? _ciEtiqueta(String texto) {
    final up = texto.toUpperCase();
    final m = RegExp(r'(?<![A-ZÁÉÍÓÚÑÜ0-9])N(?:RO|O|°|º|\.)?\s*[°º\.:]?\s*([0-9OILSB]{5,11})(?![0-9])').firstMatch(up);
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
        .where((n) => !n.startsWith('0')) // un CI no empieza con 0 (el número rojo de costado sí)
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
