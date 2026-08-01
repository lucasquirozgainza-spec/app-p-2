import '../db/database_helper.dart';
import 'app_state.dart';
import 'cloud.dart';
import 'device_context.dart';

/// Botón de pánico (SOS): avisa al admin por la nube con ubicación y deja
/// registro en advertencias.
class Sos {
  static Future<void> enviar() async {
    final s = AppState.instance;
    final gps = await DeviceContext.gps();
    final ubic = gps != null ? '${gps['lat']},${gps['lng']}' : '';
    Cloud.evento('SOS',
        guardia: s.userNombre ?? 'Guardia',
        detalle: {'ubicacion': ubic, 'edificio': s.edificioNombre});
    Cloud.heartbeat(lat: gps?['lat'], lng: gps?['lng']);
    try {
      final db = await DB.instance.database;
      await db.insert('advertencias', {
        'guardia_nombre': s.userNombre ?? 'Guardia',
        'mensaje': 'BOTON DE PANICO (SOS) activado por ${s.userNombre ?? 'guardia'}'
            '${ubic.isNotEmpty ? ' · ubicacion $ubic' : ''}.',
        'tipo': 'sos',
        'edificio': s.edificioId,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {}
  }
}
