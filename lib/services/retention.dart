import '../db/database_helper.dart';

/// Retención de datos: conserva un historial y borra automáticamente los
/// registros transaccionales con más de 90 días (3 meses). Los datos maestros
/// (propietarios, residentes, vehículos, contactos, normativas, usuarios)
/// NO se borran.
class Retention {
  static const int dias = 90;

  static const _tablas = [
    'ingreso_turno', 'salida_turno', 'visitas', 'rondas', 'encomiendas',
    'incidentes', 'mantenimiento', 'hospedajes', 'auditoria',
  ];

  static Future<void> purgar() async {
    final db = await DB.instance.database;
    final corte = DateTime.now().subtract(const Duration(days: dias)).toIso8601String();
    for (final t in _tablas) {
      try {
        await db.delete(t, where: 'created_at IS NOT NULL AND created_at < ?', whereArgs: [corte]);
      } catch (_) {
        // Si una tabla no tiene created_at, se ignora.
      }
    }
  }
}
