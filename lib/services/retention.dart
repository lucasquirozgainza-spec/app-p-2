import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../db/database_helper.dart';
import 'app_state.dart';
import 'cloud.dart';

/// Retención de datos: todo lo que genera la app (registros y sus fotos/videos)
/// se borra automáticamente del CELULAR pasados 3 meses (por meses completos,
/// nunca nada anterior al 1/9/2026). En la nube rige el periodo configurado. Los datos maestros (propietarios, residentes, vehículos, contactos,
/// normativas, usuarios, cámaras) NO se borran. Los PDF descargables tampoco.
/// El admin puede cambiar el periodo desde Configuración.
class Retention {
  static const _tablas = [
    'ingreso_turno', 'salida_turno', 'visitas', 'rondas', 'encomiendas',
    'incidentes', 'mantenimiento', 'hospedajes', 'advertencias', 'auditoria',
  ];

  /// Nada anterior a esta fecha se guarda en el celular.
  static final DateTime _piso = DateTime(2026, 9, 1);

  /// Corte LOCAL (en el celular): se guardan los últimos 3 meses completos
  /// más el mes actual, y nunca nada anterior al 1 de septiembre de 2026.
  /// Ej.: en noviembre queda desde el 1/9; en enero, desde el 1/10.
  static DateTime corteLocal([DateTime? hoy]) {
    final t = hoy ?? DateTime.now();
    final tresMeses = DateTime(t.year, t.month - 3, 1);
    return tresMeses.isAfter(_piso) ? tresMeses : _piso;
  }

  static Future<void> purgar() async {
    final dias = AppState.instance.retencionDias;
    final db = await DB.instance.database;
    final corte = corteLocal();
    final corteIso = corte.toIso8601String();
    for (final t in _tablas) {
      try {
        await db.delete(t, where: 'created_at IS NOT NULL AND created_at < ?', whereArgs: [corteIso]);
      } catch (_) {}
    }
    await _borrarArchivos(corte);
    // Limpiar tambien la nube: fotos (Storage) y eventos viejos, para que el
    // servidor no se llene (se "sobreescribe" manteniendo solo los ultimos meses).
    // Fotos: solo las de meses ya RESPALDADOS desde el monitor (o, como
    // seguro para no llenar la nube, las de más de [dias] + 30 días).
    // Registros (texto): se guardan 1 año como mínimo (ocupan muy poco).
    try { await Cloud.limpiarStorage(dias); } catch (_) {}
    try { await Cloud.borrarEventosViejos(dias < 365 ? 365 : dias); } catch (_) {}
  }

  /// Tablas que se vacían por completo con "Eliminar todo ahora".
  /// NO incluye: usuarios (guardias) ni edificios (configuración).
  static const _tablasWipe = [
    'ingreso_turno', 'salida_turno', 'visitas', 'rondas', 'encomiendas',
    'incidentes', 'mantenimiento', 'hospedajes', 'advertencias',
    'propietarios', 'residentes', 'vehiculos', 'contactos', 'normativas',
    'encargados', 'auditoria',
  ];

  /// Borra AHORA todos los datos registrados y de prueba (con sus fotos/videos),
  /// dejando SOLO los guardias, los edificios y las cámaras configuradas.
  /// Devuelve cuántas filas se borraron en total. También limpia la nube.
  static Future<int> borrarTodoAhora() async {
    final db = await DB.instance.database;
    int total = 0;
    for (final t in _tablasWipe) {
      try {
        total += await db.delete(t);
      } catch (_) {}
    }
    // Borrar TODAS las fotos/grabaciones (sin importar la fecha), menos PDF.
    await _borrarTodosArchivos();
    // La nube NO se toca: ahí está el historial que usa el monitor (horas,
    // informes, adelantos). Su limpieza se hace desde el monitor (Respaldo y
    // espacio) y con el borrado automático por antigüedad.
    return total;
  }

  /// Borra TODAS las fotos y videos (cualquier fecha). NUNCA borra .pdf.
  static Future<void> _borrarTodosArchivos() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (final sub in ['fotos', 'grabaciones']) {
        final d = Directory(p.join(dir.path, sub));
        if (!await d.exists()) continue;
        for (final f in d.listSync().whereType<File>()) {
          try {
            if (f.path.toLowerCase().endsWith('.pdf')) continue;
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Fecha real de la foto: va en el nombre (IMG_<microsegundos>.jpg o
  /// IMG_<milisegundos>.jpg). Si no se puede leer, la fecha del archivo.
  static DateTime fechaArchivo(File f) {
    final m = RegExp(r'(\d{13,16})').firstMatch(p.basename(f.path));
    if (m != null) {
      final g = m.group(1)!;
      final v = int.tryParse(g);
      if (v != null) {
        final d = g.length >= 16
            ? DateTime.fromMicrosecondsSinceEpoch(v)
            : DateTime.fromMillisecondsSinceEpoch(v);
        if (d.year >= 2020 && d.year <= 2100) return d;
      }
    }
    return f.statSync().modified;
  }

  /// Borra fotos y videos anteriores a [corte]. NUNCA borra archivos .pdf.
  static Future<void> _borrarArchivos(DateTime corte) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (final sub in ['fotos', 'grabaciones']) {
        final d = Directory(p.join(dir.path, sub));
        if (!await d.exists()) continue;
        for (final f in d.listSync().whereType<File>()) {
          try {
            if (f.path.toLowerCase().endsWith('.pdf')) continue; // los PDF se conservan
            if (fechaArchivo(f).isBefore(corte)) await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
