import 'package:gal/gal.dart';

/// Guarda copias de las fotos en la galería del teléfono, ordenadas POR MES y
/// por tipo, para poder borrar fácilmente los meses viejos:
///
///   Imágenes/OSIRIS/2026-11/Rondas 2026-11
///   Imágenes/OSIRIS/2026-11/Visitas 2026-11
///   Imágenes/OSIRIS/2026-11/Novedades 2026-11 ...
///
/// (En la galería cada carpeta aparece como un álbum "Rondas 2026-11", etc.;
/// en el administrador de archivos se borra la carpeta del mes entera.)
/// Nunca lanza: si falla (permiso, versión de Android) no guarda en galería.
class Gallery {
  static const Map<String, String> _tipos = {
    'rondas': 'Rondas',
    'carnet': 'Visitas',
    'tarjetas': 'Visitas',
    'visitas': 'Visitas',
    'incidentes': 'Novedades',
    'novedades': 'Novedades',
    'encomiendas': 'Encomiendas',
    'turnos': 'Turnos',
    'documentos': 'Documentos',
    'hospedajes': 'Hospedajes',
    'placas': 'Vehiculos',
    'grabaciones': 'Grabaciones',
  };

  /// "OSIRIS Rondas" -> "OSIRIS/2026-11/Rondas 2026-11"
  static String carpeta(String? album, [DateTime? cuando]) {
    final t = cuando ?? DateTime.now();
    final mes = '${t.year}-${t.month.toString().padLeft(2, '0')}';
    final clave = (album ?? '').toLowerCase().replaceAll('osiris', '').trim();
    final tipo = _tipos[clave] ?? (clave.isEmpty ? 'Otros' : clave[0].toUpperCase() + clave.substring(1));
    return 'OSIRIS/$mes/$tipo $mes';
  }

  static Future<void> guardar(String path, {String? album}) async {
    try {
      await Gal.putImage(path, album: carpeta(album));
    } catch (_) {
      // Algunos celulares no aceptan subcarpetas: álbum simple con el mes.
      try {
        await Gal.putImage(path, album: carpeta(album).split('/').last);
      } catch (_) {
        // Silencioso: la foto ya quedó guardada en la app aunque la galería falle.
      }
    }
  }
}
