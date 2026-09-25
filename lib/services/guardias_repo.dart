import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../db/database_helper.dart';
import 'app_state.dart';
import 'cloud.dart';
import 'estructura.dart';
import 'sesion.dart';

/// Guardia de la nube (tabla guards). Su [id] es único y nunca se reutiliza:
/// un reemplazo es un guardia NUEVO que empieza en cero.
class Guardia {
  final String id, buildingId, unitId, nombre, turno, rol;
  final String? documento, telefono, reemplazaA;
  final DateTime inicio;
  final DateTime? fin;
  final bool activo;
  Guardia({
    required this.id,
    required this.buildingId,
    required this.unitId,
    required this.nombre,
    required this.turno,
    required this.rol,
    required this.inicio,
    this.fin,
    this.documento,
    this.telefono,
    this.reemplazaA,
    this.activo = true,
  });

  bool get diurno => turno == 'DIURNO';

  static Guardia? de(Object? m) {
    if (m is! Map || m['id'] == null) return null;
    return Guardia(
      id: '${m['id']}',
      buildingId: '${m['building_id']}',
      unitId: '${m['unit_id']}',
      nombre: '${m['full_name'] ?? ''}'.trim(),
      turno: '${m['shift'] ?? 'DIURNO'}',
      rol: '${m['role'] ?? 'guardia'}',
      inicio: DateTime.tryParse('${m['start_date'] ?? ''}') ?? DateTime.now(),
      fin: DateTime.tryParse('${m['end_date'] ?? ''}'),
      documento: m['document']?.toString(),
      telefono: m['phone']?.toString(),
      reemplazaA: m['replaced_guard_id']?.toString(),
      activo: m['active'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'building_id': buildingId,
        'unit_id': unitId,
        'full_name': nombre,
        'shift': turno,
        'role': rol,
        'start_date': _d(inicio),
        'end_date': fin == null ? null : _d(fin!),
        'document': documento,
        'phone': telefono,
        'replaced_guard_id': reemplazaA,
        'active': activo,
      };

  static String _d(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Advertencia de un guardia.
class Advertencia {
  final String id, motivo, estado;
  final String? descripcion, registradoPor, observaciones;
  final DateTime fecha;
  Advertencia(this.id, this.motivo, this.estado, this.fecha,
      {this.descripcion, this.registradoPor, this.observaciones});
  bool get activa => estado == 'ACTIVA';
  static Advertencia? de(Object? m) {
    if (m is! Map || m['id'] == null) return null;
    return Advertencia(
      '${m['id']}',
      '${m['reason'] ?? ''}',
      '${m['status'] ?? 'ACTIVA'}',
      DateTime.tryParse('${m['occurred_at'] ?? ''}')?.toLocal() ?? DateTime.now(),
      descripcion: m['description']?.toString(),
      registradoPor: m['created_by']?.toString(),
      observaciones: m['notes']?.toString(),
    );
  }
}

/// Guardias por edificio y unidad. La nube es la fuente; se guarda una copia
/// local (para funcionar sin señal) y un espejo en la tabla local `usuarios`
/// (guard_uuid), que es lo que usan las pantallas de turno.
class GuardiasRepo {
  static String _kCache(String buildingId) => 'guards_$buildingId';

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

  /// Guardias del edificio (activos e inactivos). Un celular de guardia solo
  /// recibe los de SU unidad (lo impone la base). Sin señal: la copia local.
  static Future<List<Guardia>> delEdificio(String buildingId, {bool soloCache = false}) async {
    final p = await SharedPreferences.getInstance();
    List<Guardia> desdeCache() {
      try {
        final l = jsonDecode(p.getString(_kCache(buildingId)) ?? '[]');
        return [for (final m in (l as List)) if (Guardia.de(m) != null) Guardia.de(m)!];
      } catch (_) {
        return [];
      }
    }

    if (soloCache || !Sesion.vinculado) return desdeCache();
    try {
      final r = await http
          .get(Uri.parse('$_rest/guards?select=*&building_id=eq.$buildingId&order=active.desc,shift,full_name'),
              headers: await _h())
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return desdeCache();
      final lista = [for (final m in (jsonDecode(r.body) as List)) if (Guardia.de(m) != null) Guardia.de(m)!];
      await p.setString(_kCache(buildingId), jsonEncode([for (final g in lista) g.toJson()]));
      await _espejo(buildingId, lista);
      await cerrarTurnosHuerfanos();
      return lista;
    } catch (_) {
      return desdeCache();
    }
  }

  /// Copia los guardias de la nube a la tabla local `usuarios` (por
  /// guard_uuid). Un guardia nuevo recibe una fila NUEVA: nunca hereda la de
  /// otro. Los que ya no están activos quedan inactivos (no se borran).
  static Future<void> _espejo(String buildingId, List<Guardia> lista) async {
    final db = await DB.instance.database;
    final codigo = Estructura.edificios.where((e) => e.id == buildingId).map((e) => e.code).toList();
    final ed = codigo.isNotEmpty ? codigo.first : (Sesion.buildingCode ?? '');
    final batch = db.batch();
    for (final g in lista) {
      final datos = {
        'nombre': g.nombre,
        'cargo': g.rol == 'guardia' ? 'Guardia de Seguridad' : g.rol,
        'rol': g.rol,
        'activo': g.activo ? 1 : 0,
        'edificio': ed,
        'unit_id': g.unitId,
        'turno': g.turno,
        'documento': g.documento,
        'telefono': g.telefono,
        'fecha_inicio': Guardia._d(g.inicio),
        'fecha_fin': g.fin == null ? null : Guardia._d(g.fin!),
      };
      batch.rawInsert(
        'INSERT OR IGNORE INTO usuarios (usuario, nombre, cargo, rol, pass_hash, salt, activo, edificio, '
        'created_at, guard_uuid) VALUES (?,?,?,?,?,?,?,?,?,?)',
        ['guard_${g.id}', g.nombre, datos['cargo'], g.rol, 'nube', 'nube', datos['activo'], ed,
         DateTime.now().toIso8601String(), g.id],
      );
      batch.update('usuarios', datos, where: 'guard_uuid=?', whereArgs: [g.id]);
    }
    await batch.commit(noResult: true);
  }

  /// Turnos abiertos que ya no pertenecen a nadie válido: los del sistema
  /// anterior (sin id de guardia) y los de guardias desactivados. Se cierran
  /// SIN salida (quedan como incompletos en el historial) para que ningún
  /// guardia nuevo pueda cerrarlos ni heredar sus horas.
  static Future<void> cerrarTurnosHuerfanos() async {
    if (!Sesion.vinculado) return;
    try {
      final db = await DB.instance.database;
      await db.rawUpdate(
          "UPDATE ingreso_turno SET activo=0 WHERE activo=1 AND (guard_uuid IS NULL OR guard_uuid='' "
          'OR guard_uuid IN (SELECT guard_uuid FROM usuarios WHERE activo=0 AND guard_uuid IS NOT NULL))');
      // Si el turno del operador de este celular era uno de esos, se libera.
      final s = AppState.instance;
      if (s.turnoActivoId != null) {
        final r = await db.query('ingreso_turno', where: 'id=? AND activo=1', whereArgs: [s.turnoActivoId]);
        if (r.isEmpty) s.clearOperador();
      }
    } catch (_) {}
  }

  /// Registra un guardia NUEVO (id nuevo, todo en cero). Devuelve null si
  /// salió bien o el mensaje para mostrar.
  static Future<String?> registrar({
    required String buildingId,
    required String unitId,
    required String nombre,
    required String turno,
    String rol = 'guardia',
    String? documento,
    String? telefono,
    DateTime? inicio,
  }) async {
    try {
      final r = await http
          .post(Uri.parse('$_rest/guards'),
              headers: {...await _h(), 'Prefer': 'return=minimal'},
              body: jsonEncode({
                'building_id': buildingId,
                'unit_id': unitId,
                'full_name': nombre.trim(),
                'shift': turno,
                'role': rol,
                if (documento != null && documento.trim().isNotEmpty) 'document': documento.trim(),
                if (telefono != null && telefono.trim().isNotEmpty) 'phone': telefono.trim(),
                'start_date': Guardia._d(inicio ?? DateTime.now()),
              }))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return _msgTurno(r, turno);
      return null;
    } catch (_) {
      return 'Sin conexión: el guardia se registra con internet.';
    }
  }

  static String _msgTurno(http.Response r, String turno) {
    final m = Estructura.mensaje(r);
    if (m == 'Ya existe un registro igual.') {
      return 'Ya existe un guardia ${turno == 'DIURNO' ? 'diurno' : 'nocturno'} activo para esta unidad. '
          'Debe reemplazarlo o desactivarlo antes de registrar uno nuevo.';
    }
    return m;
  }

  /// Edita datos del guardia (no cambia su id ni su historial).
  static Future<String?> editar(Guardia g, {String? nombre, String? documento, String? telefono, String? turno,
      String? unitId}) async {
    try {
      final r = await http
          .patch(Uri.parse('$_rest/guards?id=eq.${g.id}'),
              headers: {...await _h(), 'Prefer': 'return=minimal'},
              body: jsonEncode({
                if (nombre != null) 'full_name': nombre.trim(),
                if (documento != null) 'document': documento.trim().isEmpty ? null : documento.trim(),
                if (telefono != null) 'phone': telefono.trim().isEmpty ? null : telefono.trim(),
                if (turno != null) 'shift': turno,
                if (unitId != null) 'unit_id': unitId,
              }))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return _msgTurno(r, turno ?? g.turno);
      return null;
    } catch (_) {
      return 'Sin conexión';
    }
  }

  /// Desactiva (no borra): conserva todo su historial.
  static Future<String?> desactivar(Guardia g, {DateTime? fin}) async {
    try {
      final f = fin ?? DateTime.now();
      final r = await http
          .patch(Uri.parse('$_rest/guards?id=eq.${g.id}'),
              headers: {...await _h(), 'Prefer': 'return=minimal'},
              body: jsonEncode({
                'active': false,
                'end_date': Guardia._d(f.isBefore(g.inicio) ? g.inicio : f),
              }))
          .timeout(const Duration(seconds: 15));
      return r.statusCode >= 300 ? Estructura.mensaje(r) : null;
    } catch (_) {
      return 'Sin conexión';
    }
  }

  /// Reemplazo en UNA operación en la base: desactiva al anterior y crea uno
  /// nuevo (id nuevo, horas en cero, sin advertencias ni registros).
  static Future<String?> reemplazar(Guardia g,
      {required String nombre, String? documento, String? telefono, DateTime? inicio}) async {
    try {
      final r = await http
          .post(Uri.parse('$_rest/rpc/reemplazar_guardia'),
              headers: await _h(),
              body: jsonEncode({
                'p_guard': g.id,
                'p_nombre': nombre.trim(),
                'p_documento': documento ?? '',
                'p_telefono': telefono ?? '',
                'p_inicio': Guardia._d(inicio ?? DateTime.now()),
              }))
          .timeout(const Duration(seconds: 15));
      return r.statusCode >= 300 ? Estructura.mensaje(r) : null;
    } catch (_) {
      return 'Sin conexión';
    }
  }

  // ---- Advertencias ----

  static Future<List<Advertencia>> advertencias(String guardId) async {
    try {
      final r = await http
          .get(Uri.parse('$_rest/guard_warnings?select=*&guard_id=eq.$guardId&order=occurred_at.desc'),
              headers: await _h())
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return [];
      return [for (final m in (jsonDecode(r.body) as List)) if (Advertencia.de(m) != null) Advertencia.de(m)!];
    } catch (_) {
      return [];
    }
  }

  /// Advertencias activas por guardia de un edificio (para las tarjetas).
  static Future<Map<String, int>> advertenciasActivas(String buildingId) async {
    try {
      final r = await http
          .get(Uri.parse('$_rest/guard_warnings?select=guard_id&building_id=eq.$buildingId&status=eq.ACTIVA'),
              headers: await _h())
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return {};
      final out = <String, int>{};
      for (final m in (jsonDecode(r.body) as List)) {
        final g = '${(m as Map)['guard_id']}';
        out[g] = (out[g] ?? 0) + 1;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  static Future<String?> resolverAdvertencia(String id, {String? observaciones}) async {
    try {
      final r = await http
          .patch(Uri.parse('$_rest/guard_warnings?id=eq.$id'),
              headers: {...await _h(), 'Prefer': 'return=minimal'},
              body: jsonEncode({
                'status': 'RESUELTA',
                'resolved_at': DateTime.now().toUtc().toIso8601String(),
                if (observaciones != null && observaciones.trim().isNotEmpty) 'notes': observaciones.trim(),
              }))
          .timeout(const Duration(seconds: 15));
      return r.statusCode >= 300 ? Estructura.mensaje(r) : null;
    } catch (_) {
      return 'Sin conexión';
    }
  }
}
