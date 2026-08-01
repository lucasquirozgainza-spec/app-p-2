import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:geolocator/geolocator.dart';

/// Captura datos automaticos NO editables por el usuario:
/// GPS, nivel de bateria y modelo del dispositivo.
class DeviceContext {
  static final _battery = Battery();

  /// Devuelve {lat, lng} o null si no hay permiso/GPS.
  static Future<Map<String, double>?> gps() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      // Primero intentamos la ultima ubicacion conocida (instantanea).
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        // En segundo plano se refresca; devolvemos ya para no demorar el turno.
        return {'lat': last.latitude, 'lng': last.longitude};
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 4),
      );
      return {'lat': pos.latitude, 'lng': pos.longitude};
    } catch (_) {
      return null;
    }
  }

  static Future<int?> bateria() async {
    try {
      return await _battery.batteryLevel;
    } catch (_) {
      return null;
    }
  }

  static Future<String> dispositivo() async {
    try {
      final info = DeviceInfoPlugin();
      final a = await info.androidInfo;
      return '${a.manufacturer} ${a.model} (Android ${a.version.release})';
    } catch (_) {
      return 'Desconocido';
    }
  }
}
