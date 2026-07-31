import 'package:device_info_plus/device_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_state.dart';

/// Capa ONLINE (Supabase). Cada equipo sube sus eventos y su "presencia"
/// para que el administrador vea todo en tiempo real desde su celular.
/// Si no hay internet, la app sigue funcionando offline sin problema.
class Cloud {
  // Datos del proyecto Supabase (la clave publishable es segura en apps).
  static const String url = 'https://idwsbukgtogiwvfrurlc.supabase.co';
  static const String anonKey = 'sb_publishable_-uuIV9H6rYYWjhyGNNtQww_0oww_OyF';

  static bool enabled = false;
  static String deviceId = 'device';
  static String? lastError; // ultimo error de la nube (para diagnostico)

  static SupabaseClient get _c => Supabase.instance.client;

  static Future<void> init() async {
    try {
      await Supabase.initialize(url: url, anonKey: anonKey);
      enabled = true;
    } catch (e) {
      enabled = false;
      lastError = 'init: $e';
    }
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      deviceId = info.id;
    } catch (_) {}
  }

  /// Prueba de conexión: inserta un evento de prueba y lo lee. Devuelve 'OK'
  /// o el mensaje de error para diagnosticar la sincronización.
  static Future<String> probar() async {
    if (!enabled) return 'Nube desactivada (no se pudo inicializar). ${lastError ?? ''}';
    try {
      await _c.from('eventos').insert({
        'tipo': 'Prueba de conexión',
        'edificio': AppState.instance.edificioId,
        'guardia': AppState.instance.userNombre ?? 'Prueba',
        'detalle': {'device': deviceId},
        'device_id': deviceId,
      });
      await heartbeat();
      final rows = await _c.from('eventos').select().limit(1);
      return 'OK · La nube responde (${(rows as List).length} lectura). Los datos deberían cruzarse.';
    } catch (e) {
      lastError = 'probar: $e';
      return 'ERROR: $e';
    }
  }

  /// Sube un evento (turno, visita, ronda, incidente...) a la nube.
  static Future<void> evento(String tipo, {String? guardia, Map<String, dynamic>? detalle}) async {
    if (!enabled) return;
    try {
      await _c.from('eventos').insert({
        'tipo': tipo,
        'edificio': AppState.instance.edificioId,
        'guardia': guardia ?? AppState.instance.userNombre,
        'detalle': detalle ?? {},
        'device_id': deviceId,
      });
    } catch (e) {
      lastError = 'evento: $e';
    }
  }

  /// Actualiza la presencia del equipo/guardia (para saber quién está en línea).
  static Future<void> heartbeat() async {
    if (!enabled) return;
    final s = AppState.instance;
    try {
      await _c.from('presencia').upsert({
        'device_id': deviceId,
        'guardia': s.userNombre ?? 'Sin turno',
        'edificio': s.edificioId,
        'en_turno': s.turnoActivoId != null,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'device_id');
    } catch (e) {
      lastError = 'heartbeat: $e';
    }
  }

  /// Lee eventos recientes. Si se pasa [edificio], solo trae los de ese
  /// edificio (para los guardias); sin edificio trae todos (para el admin).
  static Future<List<Map<String, dynamic>>> eventos({String? tipo, String? edificio, int limit = 120}) async {
    if (!enabled) return [];
    try {
      var q = _c.from('eventos').select();
      if (tipo != null) q = q.eq('tipo', tipo);
      if (edificio != null) q = q.eq('edificio', edificio);
      final rows = await q.order('created_at', ascending: false).limit(limit);
      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      lastError = 'eventos: $e';
      return [];
    }
  }

  /// Eventos de turno (ingreso/salida) del mes actual, de TODOS los edificios.
  static Future<List<Map<String, dynamic>>> eventosTurnoMes() async {
    if (!enabled) return [];
    try {
      final now = DateTime.now();
      final desde = DateTime(now.year, now.month, 1).toUtc().toIso8601String();
      final rows = await _c
          .from('eventos')
          .select()
          .inFilter('tipo', ['Ingreso de turno', 'Salida de turno'])
          .gte('created_at', desde)
          .order('created_at')
          .limit(2000);
      return List<Map<String, dynamic>>.from(rows);
    } catch (_) {
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> presencia() async {
    if (!enabled) return [];
    try {
      final rows = await _c.from('presencia').select().order('last_seen', ascending: false);
      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      lastError = 'presencia: $e';
      return [];
    }
  }
}
