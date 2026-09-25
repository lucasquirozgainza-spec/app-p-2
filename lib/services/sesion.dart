import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud.dart';

/// Sesión del celular en Supabase y su VÍNCULO con un edificio y una unidad
/// (torre / dispositivo).
///
/// - Cada celular inicia sesión solo (sesión anónima de Supabase, sin
///   contraseña) y se vincula UNA vez con un código que genera el
///   administrador. Desde ese momento la base sabe a qué edificio y unidad
///   pertenece, y sus políticas (RLS) le impiden ver o escribir otros.
/// - Sin vincular, la app funciona como antes (modo anterior).
class Sesion {
  static String? _access;
  static String? _refresh;
  static int _exp = 0; // segundos epoch
  static Map<String, dynamic>? _disp;

  static const _kAccess = 'sb_access', _kRefresh = 'sb_refresh', _kExp = 'sb_exp', _kDisp = 'sb_disp';

  static Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      _access = p.getString(_kAccess);
      _refresh = p.getString(_kRefresh);
      _exp = p.getInt(_kExp) ?? 0;
      final d = p.getString(_kDisp);
      if (d != null && d.isNotEmpty) {
        final m = jsonDecode(d);
        if (m is Map) _disp = Map<String, dynamic>.from(m);
      }
    } catch (_) {}
  }

  // ---- Contexto del celular ----
  static bool get vinculado => _disp != null && _disp!['active'] != false && token != null;
  static bool get esAdmin => vinculado && _disp!['role'] == 'admin';
  static bool get esGuardia => vinculado && _disp!['role'] == 'guardia';
  static String? get buildingId => _disp?['building_id']?.toString();
  static String? get buildingCode => _disp?['building_code']?.toString();
  static String? get buildingName => _disp?['building_name']?.toString();
  static String? get unitId => _disp?['unit_id']?.toString();
  static String? get unitName => _disp?['unit_name']?.toString();

  /// Token actual (puede estar vencido: usar [vigente] antes de llamar).
  static String? get token => _access;

  static Map<String, String> _base() => {'apikey': Cloud.anonKey, 'Content-Type': 'application/json'};

  static Future<void> _guardar(Map<String, dynamic> r) async {
    final a = r['access_token']?.toString();
    final rf = r['refresh_token']?.toString();
    if (a == null || rf == null) throw Exception('Respuesta de sesión incompleta');
    _access = a;
    _refresh = rf;
    final expIn = (r['expires_in'] is num) ? (r['expires_in'] as num).toInt() : 3600;
    _exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + expIn;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAccess, a);
    await p.setString(_kRefresh, rf);
    await p.setInt(_kExp, _exp);
  }

  static bool _renovando = false;

  /// Deja el token vigente (lo renueva si vence en menos de 2 min). Nunca
  /// lanza: sin señal se sigue con el que hay (el envío se reintenta luego).
  static Future<void> vigente() async {
    if (_refresh == null) return;
    final ahora = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_access != null && _exp - ahora > 120) return;
    if (_renovando) return;
    _renovando = true;
    try {
      final r = await http
          .post(Uri.parse('${Cloud.url}/auth/v1/token?grant_type=refresh_token'),
              headers: _base(), body: jsonEncode({'refresh_token': _refresh}))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode < 300) {
        await _guardar(Map<String, dynamic>.from(jsonDecode(r.body) as Map));
      }
    } catch (_) {
    } finally {
      _renovando = false;
    }
  }

  /// Inicia una sesión anónima si no hay ninguna.
  static Future<void> _asegurarSesion() async {
    if (_refresh != null) {
      await vigente();
      return;
    }
    final r = await http
        .post(Uri.parse('${Cloud.url}/auth/v1/signup'), headers: _base(), body: jsonEncode({'data': {}}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode >= 300) {
      throw Exception(r.statusCode == 422 || r.body.contains('anonymous')
          ? 'Supabase no permite sesiones anónimas: actívalas en Authentication.'
          : 'No se pudo iniciar sesión (${r.statusCode}).');
    }
    await _guardar(Map<String, dynamic>.from(jsonDecode(r.body) as Map));
  }

  static String _mensaje(http.Response r) {
    try {
      final m = jsonDecode(r.body);
      if (m is Map && m['message'] != null) return m['message'].toString();
    } catch (_) {}
    return 'Error ${r.statusCode}';
  }

  /// Vincula este celular con el código. Devuelve null si salió bien o el
  /// mensaje de error.
  static Future<String?> activar(String codigo, {String? etiqueta}) async {
    try {
      await _asegurarSesion();
      final r = await http
          .post(Uri.parse('${Cloud.url}/rest/v1/rpc/activar_dispositivo'),
              headers: {..._base(), 'Authorization': 'Bearer $_access'},
              body: jsonEncode({
                'p_codigo': codigo.trim().toUpperCase(),
                'p_device_id': Cloud.deviceId,
                'p_label': etiqueta,
              }))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode >= 300) return _mensaje(r);
      final m = jsonDecode(r.body);
      if (m is! Map) return 'Respuesta inesperada';
      await _guardarDisp(Map<String, dynamic>.from(m));
      return null;
    } catch (e) {
      return '$e'.replaceFirst('Exception: ', '');
    }
  }

  static Future<void> _guardarDisp(Map<String, dynamic>? d) async {
    _disp = d;
    final p = await SharedPreferences.getInstance();
    if (d == null) {
      await p.remove(_kDisp);
    } else {
      await p.setString(_kDisp, jsonEncode(d));
    }
  }

  static DateTime? _ultimaRevision;

  /// Relee el vínculo (el admin pudo desactivar este celular o moverlo de
  /// unidad). Como máximo cada 10 min salvo [forzar].
  static Future<void> revisar({bool forzar = false}) async {
    if (_refresh == null || _disp == null) return;
    final ahora = DateTime.now();
    if (!forzar && _ultimaRevision != null && ahora.difference(_ultimaRevision!).inMinutes < 10) return;
    _ultimaRevision = ahora;
    try {
      await vigente();
      final r = await http
          .post(Uri.parse('${Cloud.url}/rest/v1/rpc/mi_dispositivo'),
              headers: {..._base(), 'Authorization': 'Bearer $_access'}, body: '{}')
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return;
      final m = jsonDecode(r.body);
      if (m is Map) {
        await _guardarDisp(Map<String, dynamic>.from(m));
      } else if (m == null) {
        await _guardarDisp({...?_disp, 'active': false}); // ya no está vinculado
      }
    } catch (_) {}
  }

  /// Quita el vínculo de ESTE celular (no borra nada en la nube).
  static Future<void> desvincular() async {
    _access = null;
    _refresh = null;
    _exp = 0;
    final p = await SharedPreferences.getInstance();
    for (final k in [_kAccess, _kRefresh, _kExp]) {
      await p.remove(k);
    }
    await _guardarDisp(null);
  }
}
