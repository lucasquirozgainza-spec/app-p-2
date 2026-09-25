import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud.dart';
import 'sesion.dart';

/// Edificio en la nube.
class Edificio {
  final String id, code, name;
  Edificio(this.id, this.code, this.name);
  Map<String, dynamic> toJson() => {'id': id, 'code': code, 'name': name};
  static Edificio? de(Object? m) => m is Map && m['id'] != null && m['code'] != null
      ? Edificio('${m['id']}', '${m['code']}', '${m['name'] ?? m['code']}')
      : null;
}

/// Unidad operativa (torre / dispositivo) de un edificio.
class Unidad {
  final String id, buildingId, name;
  Unidad(this.id, this.buildingId, this.name);
  Map<String, dynamic> toJson() => {'id': id, 'building_id': buildingId, 'name': name};
  static Unidad? de(Object? m) => m is Map && m['id'] != null && m['building_id'] != null
      ? Unidad('${m['id']}', '${m['building_id']}', '${m['name'] ?? ''}')
      : null;
}

/// Estructura EDIFICIO → UNIDAD en la nube, con copia local para funcionar
/// sin señal. El edificio de trabajo es el de Configuración (AppState): esta
/// clase solo traduce su código al id de la nube y lista sus unidades.
class Estructura {
  static final Map<String, Edificio> _porCodigo = {};
  static final List<Unidad> _unidades = [];
  static const _kCache = 'estructura_cache';

  static Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kCache);
      if (raw != null) _aplicar(jsonDecode(raw));
    } catch (_) {}
  }

  static void _aplicar(Object? j) {
    if (j is! Map) return;
    _porCodigo.clear();
    for (final b in (j['buildings'] as List? ?? const [])) {
      final e = Edificio.de(b);
      if (e != null) _porCodigo[e.code] = e;
    }
    _unidades
      ..clear()
      ..addAll([for (final u in (j['units'] as List? ?? const [])) if (Unidad.de(u) != null) Unidad.de(u)!]);
  }

  /// Id en la nube del edificio con ese código (null si no está publicado).
  static String? idEdificio(String codigo) {
    if (Sesion.esGuardia && Sesion.buildingCode == codigo) return Sesion.buildingId;
    return _porCodigo[codigo]?.id;
  }

  static Edificio? edificio(String codigo) => _porCodigo[codigo];
  static List<Edificio> get edificios => _porCodigo.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  /// Unidades del edificio (en orden de nombre).
  static List<Unidad> unidades(String? buildingId) =>
      _unidades.where((u) => u.buildingId == buildingId).toList()..sort((a, b) => a.name.compareTo(b.name));

  static String nombreUnidad(String? unitId) {
    for (final u in _unidades) {
      if (u.id == unitId) return u.name;
    }
    return Sesion.unitId == unitId ? (Sesion.unitName ?? '') : '';
  }

  static Future<Map<String, String>> _h() async {
    await Sesion.vigente();
    return {
      'apikey': Cloud.anonKey,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (Sesion.token != null) 'Authorization': 'Bearer ${Sesion.token}',
    };
  }

  static String get _rest => '${Cloud.url}/rest/v1';

  static String mensaje(http.Response r) {
    try {
      final m = jsonDecode(r.body);
      if (m is Map) {
        final code = '${m['code'] ?? ''}';
        if (code == '23505') return 'Ya existe un registro igual.';
        if (code == '42501') return 'Sin permiso para esta acción.';
        if (m['message'] != null) return '${m['message']}';
      }
    } catch (_) {}
    return 'Error ${r.statusCode}';
  }

  /// Relee edificios y unidades de la nube (lo que este celular puede ver).
  static Future<void> actualizar() async {
    if (!Sesion.vinculado) return;
    try {
      final h = await _h();
      final res = await Future.wait([
        http.get(Uri.parse('$_rest/buildings?select=id,code,name&active=eq.true&order=name'), headers: h)
            .timeout(const Duration(seconds: 15)),
        http.get(Uri.parse('$_rest/units?select=id,building_id,name&active=eq.true&order=name'), headers: h)
            .timeout(const Duration(seconds: 15)),
      ]);
      if (res[0].statusCode >= 300 || res[1].statusCode >= 300) return;
      final j = {'buildings': jsonDecode(res[0].body), 'units': jsonDecode(res[1].body)};
      _aplicar(j);
      final p = await SharedPreferences.getInstance();
      await p.setString(_kCache, jsonEncode(j));
    } catch (_) {}
  }

  /// (Admin) Publica en la nube un edificio creado en este celular, con su
  /// unidad "Principal". Devuelve el id o null.
  static Future<String?> publicarEdificio(String codigo, String nombre) async {
    if (!Sesion.esAdmin) return null;
    final ya = idEdificio(codigo);
    if (ya != null) return ya;
    try {
      final r = await http
          .post(Uri.parse('$_rest/buildings?on_conflict=code'),
              headers: {...await _h(), 'Prefer': 'resolution=merge-duplicates,return=representation'},
              body: jsonEncode({'code': codigo, 'name': nombre}))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return null;
      final l = jsonDecode(r.body);
      final e = l is List && l.isNotEmpty ? Edificio.de(l.first) : null;
      if (e == null) return null;
      _porCodigo[e.code] = e;
      if (unidades(e.id).isEmpty) await crearUnidad(e.id, 'Principal');
      await actualizar();
      return e.id;
    } catch (_) {
      return null;
    }
  }

  /// (Admin) Nueva unidad (torre / dispositivo). Devuelve null o el error.
  static Future<String?> crearUnidad(String buildingId, String nombre) async {
    try {
      final r = await http
          .post(Uri.parse('$_rest/units'),
              headers: {...await _h(), 'Prefer': 'return=minimal'},
              body: jsonEncode({'building_id': buildingId, 'name': nombre.trim()}))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return mensaje(r);
      await actualizar();
      return null;
    } catch (e) {
      return 'Sin conexión';
    }
  }

  /// (Admin) Renombrar una unidad.
  static Future<String?> renombrarUnidad(String unitId, String nombre) async {
    try {
      final r = await http
          .patch(Uri.parse('$_rest/units?id=eq.$unitId'),
              headers: {...await _h(), 'Prefer': 'return=minimal'}, body: jsonEncode({'name': nombre.trim()}))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return mensaje(r);
      await actualizar();
      return null;
    } catch (_) {
      return 'Sin conexión';
    }
  }

  /// (Admin) Código para vincular un celular a [unitId] (o un admin).
  /// Devuelve {codigo} o {error}.
  static Future<Map<String, String>> crearCodigo({String? buildingId, String? unitId, bool admin = false}) async {
    try {
      final r = await http
          .post(Uri.parse('$_rest/rpc/crear_codigo'),
              headers: await _h(),
              body: jsonEncode({
                'p_building': buildingId,
                'p_unit': unitId,
                'p_role': admin ? 'admin' : 'guardia',
                'p_usos': 1,
              }))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return {'error': mensaje(r)};
      return {'codigo': '${jsonDecode(r.body)}'};
    } catch (_) {
      return {'error': 'Sin conexión'};
    }
  }

  /// (Admin) Celulares vinculados a un edificio.
  static Future<List<Map<String, dynamic>>> dispositivos(String buildingId) async {
    try {
      final r = await http
          .get(Uri.parse('$_rest/devices?select=device_id,label,role,unit_id,active,activated_at'
              '&building_id=eq.$buildingId&order=activated_at.desc'), headers: await _h())
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return [];
      return List<Map<String, dynamic>>.from(jsonDecode(r.body) as List);
    } catch (_) {
      return [];
    }
  }

  /// (Admin) Desactiva un celular (pierde el acceso a la base).
  static Future<String?> desactivarDispositivo(String deviceId) async {
    try {
      final r = await http
          .patch(Uri.parse('$_rest/devices?device_id=eq.${Uri.encodeComponent(deviceId)}'),
              headers: {...await _h(), 'Prefer': 'return=minimal'}, body: jsonEncode({'active': false}))
          .timeout(const Duration(seconds: 15));
      return r.statusCode >= 300 ? mensaje(r) : null;
    } catch (_) {
      return 'Sin conexión';
    }
  }
}
