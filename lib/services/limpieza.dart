import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'img_util.dart';
import 'retention.dart';

/// Libera espacio del celular (la app llegó a ocupar decenas de GB):
/// 1. Borra temporales viejos (caché de la cámara, fotos selladas para
///    WhatsApp, restos de compresión). No son registros: son copias.
/// 2. ACHICA las fotos viejas pesadas (las de 3-5 MB de versiones anteriores)
///    a 1600 px: la foto sigue en su lugar y se ve igual en la app,
///    pero pasa a pesar ≈10 veces menos. No borra ninguna foto.
/// Corre en segundo plano al abrir la app, poco a poco, sin trabar nada.
class Limpieza {
  static bool _corriendo = false;
  static DateTime _ocupadoHasta = DateTime.now();
  static const int _maxPorVez = 150; // fotos achicadas por apertura de la app

  /// Avisa que el guardia está usando la cámara o guardando: la limpieza se
  /// detiene unos minutos para no robarle velocidad.
  static void ocupado([Duration d = const Duration(minutes: 3)]) {
    final h = DateTime.now().add(d);
    if (h.isAfter(_ocupadoHasta)) _ocupadoHasta = h;
  }

  static Future<void> _esperarLibre() async {
    while (DateTime.now().isBefore(_ocupadoHasta) || ImgUtil.pendientes > 0) {
      await Future.delayed(const Duration(seconds: 5));
    }
  }
  static const int _pesada = 900 * 1024; // más de 900 KB = se achica

  static Future<void> correr() async {
    if (_corriendo) return;
    _corriendo = true;
    try {
      // Arranca 1 minuto después de abrir la app (el arranque va primero).
      await Future.delayed(const Duration(minutes: 1));
      await _esperarLibre();
      await _temporales();
      await _achicarFotos();
    } catch (_) {
    } finally {
      _corriendo = false;
    }
  }

  static Future<void> _temporales() async {
    try {
      final tmp = await getTemporaryDirectory();
      final corte = DateTime.now().subtract(const Duration(hours: 6));
      if (!await tmp.exists()) return;
      await for (final e in tmp.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          if ((await e.stat()).modified.isBefore(corte)) await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<void> _achicarFotos() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final d = Directory(p.join(docs.path, 'fotos'));
      if (!await d.exists()) return;
      final ahora = DateTime.now();
      final corte = Retention.corteLocal();
      final lista = <File>[];
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File) lista.add(e);
      }
      int n = 0;
      for (final f in lista) {
        try {
          final nombre = p.basename(f.path).toLowerCase();
          final st = await f.stat();
          final edad = ahora.difference(st.modified);
          // Restos de compresiones cortadas.
          if ((nombre.endsWith('.tmp') || nombre.startsWith('n_')) && edad.inHours >= 1) {
            await f.delete();
            continue;
          }
          final esFoto = nombre.endsWith('.jpg') || nombre.endsWith('.jpeg');
          // Solo fotos pesadas y que no se estén usando ahora mismo.
          if (!esFoto || st.size <= _pesada || edad.inMinutes < 15) continue;
          if (Retention.fechaArchivo(f).isBefore(corte)) continue; // se borrará
          if (n >= _maxPorVez) break; // el resto, la próxima vez
          await _esperarLibre();
          await ImgUtil.normalizarNativa(f.path);
          // Conserva la fecha original del archivo (para el borrado por meses).
          try { await f.setLastModified(st.modified); } catch (_) {}
          n++;
          await Future.delayed(const Duration(milliseconds: 400)); // sin acaparar
        } catch (_) {}
      }
    } catch (_) {}
  }
}
