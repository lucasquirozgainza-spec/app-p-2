import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:device_info_plus/device_info_plus.dart';
import 'app_state.dart';

/// Comprime una foto para la nube: máx 1080 px y JPEG calidad 55 (~80-150 KB).
/// Se ejecuta en un isolate (compute) para no trabar la interfaz.
Uint8List? _comprimirFotoBytes(Uint8List input) {
  try {
    final decoded = img.decodeImage(input);
    if (decoded == null) return null;
    final resized = decoded.width > 1080 ? img.copyResize(decoded, width: 1080) : decoded;
    return Uint8List.fromList(img.encodeJpg(resized, quality: 55));
  } catch (_) {
    return null;
  }
}

/// Capa ONLINE con REST directo a Supabase (PostgREST).
///
/// Importante: las claves nuevas de Supabase (sb_publishable_...) SOLO se
/// pueden enviar en el header `apikey`, NO en `Authorization: Bearer`. Por eso
/// usamos REST directo (y no la librería supabase_flutter, que manda el Bearer
/// y provocaba error 401 → los datos no se cruzaban).
class Cloud {
  static const String url = 'https://idwsbukgtogiwvfrurlc.supabase.co';
  static const String anonKey = 'sb_publishable_-uuIV9H6rYYWjhyGNNtQww_0oww_OyF';
  static const String _rest = '$url/rest/v1';

  static bool enabled = true;
  static String deviceId = 'device';
  static String? lastError;

  static Map<String, String> get _h => {
        'apikey': anonKey,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  static Future<void> init() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      deviceId = info.id;
    } catch (_) {}
    enabled = true;
  }

  /// Prueba de conexión: inserta un evento de prueba y lee la tabla.
  static Future<String> probar() async {
    try {
      final r = await http.post(
        Uri.parse('$_rest/eventos'),
        headers: {..._h, 'Prefer': 'return=minimal'},
        body: jsonEncode({
          'tipo': 'Prueba de conexión',
          'edificio': AppState.instance.edificioId,
          'guardia': AppState.instance.userNombre ?? 'Prueba',
          'detalle': {'device': deviceId},
          'device_id': deviceId,
        }),
      );
      if (r.statusCode >= 200 && r.statusCode < 300) {
        await heartbeat();
        return 'OK · La nube respondió (código ${r.statusCode}). Los datos deberían cruzarse entre celulares.';
      }
      lastError = 'probar ${r.statusCode}: ${r.body}';
      return 'ERROR ${r.statusCode}: ${r.body}';
    } catch (e) {
      lastError = 'probar: $e';
      return 'ERROR de red: $e';
    }
  }

  /// Sube un evento (turno, visita, ronda, incidente...) a la nube.
  static Future<void> evento(String tipo, {String? guardia, Map<String, dynamic>? detalle}) async {
    if (AppState.instance.soloLocal) return; // edificio sin conexión
    try {
      final r = await http.post(
        Uri.parse('$_rest/eventos'),
        headers: {..._h, 'Prefer': 'return=minimal'},
        body: jsonEncode({
          'tipo': tipo,
          'edificio': AppState.instance.edificioId,
          'guardia': guardia ?? AppState.instance.userNombre,
          'detalle': detalle ?? {},
          'device_id': deviceId,
        }),
      ).timeout(const Duration(seconds: 12));
      if (r.statusCode >= 300) lastError = 'evento ${r.statusCode}: ${r.body}';
    } catch (e) {
      lastError = 'evento: $e';
    }
  }

  /// Actualiza la presencia del equipo/guardia (upsert por device_id).
  /// Si se pasan lat/lng, guarda la ubicacion actual (monitoreo constante).
  static Future<void> heartbeat({double? lat, double? lng}) async {
    final s = AppState.instance;
    if (s.soloLocal) return; // edificio sin conexión
    try {
      final body = <String, dynamic>{
        'device_id': deviceId,
        'guardia': s.userNombre ?? 'Sin turno',
        'edificio': s.edificioId,
        'en_turno': s.turnoActivoId != null,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      };
      if (lat != null && lng != null) {
        body['lat'] = lat;
        body['lng'] = lng;
      }
      final uri = Uri.parse('$_rest/presencia?on_conflict=device_id');
      final headers = {..._h, 'Prefer': 'resolution=merge-duplicates,return=minimal'};
      var r = await http.post(uri, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 12));
      // Si la tabla no tiene columnas lat/lng (no se corrió esa migración en
      // Supabase), reintenta sin ubicacion para no cortar la presencia.
      if (r.statusCode >= 300 && body.containsKey('lat')) {
        body.remove('lat');
        body.remove('lng');
        r = await http.post(uri, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 12));
      }
      if (r.statusCode >= 300) lastError = 'heartbeat ${r.statusCode}: ${r.body}';
    } catch (e) {
      lastError = 'heartbeat: $e';
    }
  }

  /// Lee eventos recientes. Con [edificio] solo trae los de ese edificio.
  static Future<List<Map<String, dynamic>>> eventos({String? tipo, String? edificio, int limit = 120}) async {
    if (AppState.instance.soloLocal) return [];
    try {
      final params = <String>['select=*', 'order=created_at.desc', 'limit=$limit'];
      if (tipo != null) params.add('tipo=eq.${Uri.encodeComponent(tipo)}');
      if (edificio != null) params.add('edificio=eq.${Uri.encodeComponent(edificio)}');
      final r = await http.get(Uri.parse('$_rest/eventos?${params.join('&')}'), headers: _h)
          .timeout(const Duration(seconds: 25));
      if (r.statusCode >= 300) {
        lastError = 'eventos ${r.statusCode}: ${r.body}';
        return [];
      }
      return List<Map<String, dynamic>>.from(jsonDecode(r.body) as List);
    } catch (e) {
      lastError = 'eventos: $e';
      return [];
    }
  }

  /// Eventos de turno (ingreso/salida) del mes actual, de TODOS los edificios.
  static Future<List<Map<String, dynamic>>> eventosTurnoMes() async {
    try {
      final now = DateTime.now();
      final desde = DateTime(now.year, now.month, 1).toUtc().toIso8601String();
      final inval = '("Ingreso de turno","Salida de turno")';
      final params = [
        'select=*',
        'tipo=in.${Uri.encodeComponent(inval)}',
        'created_at=gte.${Uri.encodeComponent(desde)}',
        'order=created_at.asc',
        'limit=2000',
      ];
      final r = await http.get(Uri.parse('$_rest/eventos?${params.join('&')}'), headers: _h);
      if (r.statusCode >= 300) {
        lastError = 'turnos ${r.statusCode}: ${r.body}';
        return [];
      }
      return List<Map<String, dynamic>>.from(jsonDecode(r.body) as List);
    } catch (e) {
      lastError = 'turnos: $e';
      return [];
    }
  }

  /// Borra eventos de la nube (para liberar espacio en Supabase). Si se pasa
  /// [edificio], solo borra los de ese edificio; sin edificio, borra todos.
  static Future<bool> borrarEventos({String? edificio}) async {
    try {
      final filtro = edificio != null
          ? 'edificio=eq.${Uri.encodeComponent(edificio)}'
          : 'id=gte.0'; // PostgREST exige un filtro; este abarca todos.
      final r = await http.delete(Uri.parse('$_rest/eventos?$filtro'), headers: _h)
          .timeout(const Duration(seconds: 25));
      if (r.statusCode >= 300) {
        lastError = 'borrar ${r.statusCode}: ${r.body}';
        return false;
      }
      return true;
    } catch (e) {
      lastError = 'borrar: $e';
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> presencia() async {
    if (AppState.instance.soloLocal) return [];
    try {
      final r = await http.get(Uri.parse('$_rest/presencia?select=*&order=last_seen.desc'), headers: _h)
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) {
        lastError = 'presencia ${r.statusCode}: ${r.body}';
        return [];
      }
      return List<Map<String, dynamic>>.from(jsonDecode(r.body) as List);
    } catch (e) {
      lastError = 'presencia: $e';
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // ALMACENAMIENTO DE FOTOS (Supabase Storage, bucket "osiris")
  // Sube una copia COMPRIMIDA (para ver entre dispositivos). El original en
  // máxima calidad se queda en el teléfono y se comparte por WhatsApp.
  // ---------------------------------------------------------------------------
  static const String _storage = '$url/storage/v1';
  static const String bucket = 'osiris';

  static String _edSafe() =>
      AppState.instance.edificioId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');

  /// Sube UNA foto comprimida y devuelve su URL pública (o null si falla).
  static Future<String?> subirFoto(String path, {String sufijo = ''}) async {
    if (AppState.instance.soloLocal) return null; // edificio sin conexión
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final raw = await f.readAsBytes();
      final small = await compute(_comprimirFotoBytes, raw) ?? raw;
      final name = '${_edSafe()}/${DateTime.now().millisecondsSinceEpoch}_$deviceId$sufijo.jpg';
      final r = await http
          .post(Uri.parse('$_storage/object/$bucket/$name'),
              headers: {'apikey': anonKey, 'Content-Type': 'image/jpeg', 'x-upsert': 'true'},
              body: small)
          .timeout(const Duration(seconds: 30));
      if (r.statusCode >= 300) {
        lastError = 'subirFoto ${r.statusCode}: ${r.body}';
        return null;
      }
      return '$_storage/object/public/$bucket/$name';
    } catch (e) {
      lastError = 'subirFoto: $e';
      return null;
    }
  }

  /// Sube varias fotos (hasta [max]) y devuelve la lista de URLs subidas.
  static Future<List<String>> subirFotos(List<String> paths, {int max = 6}) async {
    final urls = <String>[];
    for (int i = 0; i < paths.length && i < max; i++) {
      final u = await subirFoto(paths[i], sufijo: '_$i');
      if (u != null) urls.add(u);
    }
    return urls;
  }

  /// Borra del Storage las fotos del edificio con más de [dias] días.
  static Future<void> limpiarStorage(int dias) async {
    try {
      final ed = _edSafe();
      final corte = DateTime.now().subtract(Duration(days: dias)).millisecondsSinceEpoch;
      final r = await http
          .post(Uri.parse('$_storage/object/list/$bucket'),
              headers: _h,
              body: jsonEncode({'prefix': '$ed/', 'limit': 1000, 'sortBy': {'column': 'name', 'order': 'asc'}}))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode >= 300) return;
      final items = jsonDecode(r.body) as List;
      final viejos = <String>[];
      for (final it in items) {
        final n = (it is Map ? it['name']?.toString() : null) ?? '';
        final millis = int.tryParse(n.split('_').first) ?? 0;
        if (millis > 0 && millis < corte) viejos.add('$ed/$n');
      }
      await _borrarObjetos(viejos);
    } catch (e) {
      lastError = 'limpiarStorage: $e';
    }
  }

  /// Borra TODAS las fotos del edificio en Storage (para "Eliminar todo ahora").
  static Future<void> borrarStorageEdificio() async {
    try {
      final ed = _edSafe();
      final r = await http
          .post(Uri.parse('$_storage/object/list/$bucket'),
              headers: _h,
              body: jsonEncode({'prefix': '$ed/', 'limit': 1000}))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode >= 300) return;
      final items = jsonDecode(r.body) as List;
      final todos = <String>[
        for (final it in items)
          if (it is Map && it['name'] != null) '$ed/${it['name']}'
      ];
      await _borrarObjetos(todos);
    } catch (e) {
      lastError = 'borrarStorageEdificio: $e';
    }
  }

  static Future<void> _borrarObjetos(List<String> rutas) async {
    if (rutas.isEmpty) return;
    try {
      await http
          .delete(Uri.parse('$_storage/object/$bucket'),
              headers: {..._h}, body: jsonEncode({'prefixes': rutas}))
          .timeout(const Duration(seconds: 25));
    } catch (_) {}
  }
}
