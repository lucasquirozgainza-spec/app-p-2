import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../db/database_helper.dart';
import 'app_state.dart';
import 'cloud.dart';

/// Retención de datos: todo lo que genera la app (registros y sus fotos/videos)
/// se borra automáticamente después del periodo configurado (por defecto 3
/// meses). Los datos maestros (propietarios, residentes, vehículos, contactos,
/// normativas, usuarios, cámaras) NO se borran. Los PDF descargables tampoco.
/// El admin puede cambiar el periodo desde Configuración.
class Retention {
  static const _tablas = [
    'ingreso_turno', 'salida_turno', 'visitas', 'rondas', 'encomiendas',
    'incidentes', 'mantenimiento', 'hospedajes', 'advertencias', 'auditoria',
  ];

  static Future<void> purgar() async {
    final dias = AppState.instance.retencionDias;
    final db = await DB.instance.database;
    final corteIso = DateTime.now().subtract(Duration(days: dias)).toIso8601String();
    for (final t in _tablas) {
      try {
        await db.delete(t, where: 'created_at IS NOT NULL AND created_at < ?', whereArgs: [corteIso]);
      } catch (_) {}
    }
    await _borrarArchivos(dias);
    // Limpiar tambien las fotos viejas en la nube (Storage).
    try { await Cloud.limpiarStorage(dias); } catch (_) {}
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
    // Limpiar los eventos y las fotos de la nube de este edificio.
    try {
      await Cloud.borrarEventos(edificio: AppState.instance.edificioId);
    } catch (_) {}
    try {
      await Cloud.borrarStorageEdificio();
    } catch (_) {}
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

  /// Borra fotos y videos con más de [dias] días. NUNCA borra archivos .pdf.
  static Future<void> _borrarArchivos(int dias) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final corte = DateTime.now().subtract(Duration(days: dias));
      for (final sub in ['fotos', 'grabaciones']) {
        final d = Directory(p.join(dir.path, sub));
        if (!await d.exists()) continue;
        for (final f in d.listSync().whereType<File>()) {
          try {
            if (f.path.toLowerCase().endsWith('.pdf')) continue; // los PDF se conservan
            if (f.statSync().modified.isBefore(corte)) await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
