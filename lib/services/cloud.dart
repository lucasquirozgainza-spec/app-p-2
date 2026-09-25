import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../db/database_helper.dart';
import 'estructura.dart';
import 'sesion.dart';
import 'app_state.dart';
import 'img_util.dart';

/// Comprime una foto para la nube: máx 1080 px y JPEG calidad 55 (~80-150 KB).
/// Se ejecuta en un isolate (compute) para no trabar la interfaz.
Uint8List? _comprimirFotoBytes(Uint8List input) {
  try {
    final decoded = img.decodeImage(input);
    if (decoded == null) return null;
    // Aplicar la orientación EXIF para que la miniatura no salga volteada.
    final upright = img.bakeOrientation(decoded);
    final resized = upright.width > 1080 ? img.copyResize(upright, width: 1080) : upright;
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

  /// Encabezados solo con la clave pública (almacenamiento de fotos).
  static Map<String, String> get _hAnon => {
        'apikey': anonKey,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  /// Encabezados de la base: con la sesión del celular vinculado (así la
  /// base aplica sus políticas por edificio); sin vincular, la clave pública.
  static Map<String, String> get _h => {
        ..._hAnon,
        if (Sesion.token != null) 'Authorization': 'Bearer ${Sesion.token}',
      };

  static Future<Map<String, String>> _hdr() async {
    await Sesion.vigente();
    return _h;
  }

  static Future<void> init() async {
    // ID ÚNICO por instalación. OJO: androidInfo.id es el Build.ID del sistema
    // y es IGUAL en teléfonos del mismo modelo/firmware, así que NO sirve para
    // distinguir dispositivos (hacía que las presencias se pisaran entre sí y
    // que un guardia "tapara" a otro). Generamos un id propio y lo guardamos.
    try {
      final prefs = await SharedPreferences.getInstance();
      var uid = prefs.getString('device_uid');
      if (uid == null || uid.isEmpty) {
        String base = '';
        try {
          final info = await DeviceInfoPlugin().androidInfo;
          base = '${info.manufacturer}_${info.model}'.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
        } catch (_) {}
        final rnd = Random();
        final r = List.generate(12, (_) => rnd.nextInt(36).toRadixString(36)).join();
        uid = '${base}_${DateTime.now().millisecondsSinceEpoch}_$r';
        await prefs.setString('device_uid', uid);
      }
      deviceId = uid;
    } catch (_) {
      // Sin preferencias: id temporal propio (nunca el genérico "device",
      // que es igual en todos los celulares).
      if (deviceId == 'device') deviceId = 'tmp_${DateTime.now().microsecondsSinceEpoch}';
    }
    enabled = true;
  }

  /// Prueba de conexión: inserta un evento de prueba y lee la tabla.
  static Future<String> probar() async {
    try {
      final r = await http.post(
        Uri.parse('$_rest/eventos'),
        headers: {...await _hdr(), 'Prefer': 'return=minimal'},
        body: jsonEncode({
          'tipo': 'Prueba de conexión',
          'edificio': AppState.instance.edificioId,
          'guardia': AppState.instance.userNombre ?? 'Prueba',
          'detalle': {'device': deviceId},
          'device_id': deviceId,
        }),
      ).timeout(const Duration(seconds: 15));
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
  ///
  /// El evento se guarda PRIMERO en la cola local (tabla cola_nube) y después
  /// se envía. Así, sin señal no se pierde: se reintenta en cada latido.
  /// Cada evento lleva un `uid` único y la hora REAL (`ts`) en el detalle:
  /// - el uid evita duplicados si un envío llegó al servidor pero la respuesta
  ///   se cortó (antes de reenviar se pregunta si ya existe);
  /// - ts es la hora en que pasó, aunque se suba horas después (created_at
  ///   en la nube es la hora de SUBIDA).
  /// [edificio]: por defecto el activo de este celular.
  /// [guardId]: guardia al que pertenece el registro (por defecto el que está
  /// de turno en este celular). Con el celular vinculado, cada evento lleva
  /// además building_id / unit_id / guard_id: así las horas y los registros
  /// de un guardia se calculan SOLO con lo suyo, y la base puede separar
  /// edificios con sus políticas.
  static Future<void> evento(String tipo,
      {String? guardia, String? edificio, String? guardId, Map<String, dynamic>? detalle}) async {
    if (AppState.instance.soloLocal) return; // edificio sin conexión
    final ed = edificio ?? AppState.instance.edificioId;
    await _encolar({
      'tipo': tipo,
      'edificio': ed,
      'guardia': guardia ?? AppState.instance.userNombre,
      // Se adjunta el bloque de este celular para distinguir el origen
      // dentro del mismo edificio (los dos bloques cruzan datos igual).
      'detalle': {
        ...(detalle ?? const {}),
        if (AppState.instance.bloque.isNotEmpty) 'bloque': AppState.instance.bloque,
      },
      ..._contexto(ed, guardId ?? AppState.instance.guardUuid),
    });
  }

  /// Columnas de contexto (solo con el celular vinculado: sin la migración
  /// de la base esas columnas no existen).
  static Map<String, dynamic> _contexto(String edificio, String? guardId) {
    if (!Sesion.vinculado) return const {};
    final bid = Sesion.esGuardia ? Sesion.buildingId : Estructura.idEdificio(edificio);
    if (bid == null) return const {};
    return {
      'building_id': bid,
      if (Sesion.esGuardia) 'unit_id': Sesion.unitId,
      // El guardia debe ser de ESE edificio (la base lo verifica).
      if (guardId != null && guardId.isNotEmpty) 'guard_id': guardId,
    };
  }

  static int _seq = 0;
  static String nuevoUid() =>
      '${deviceId}_${DateTime.now().microsecondsSinceEpoch}_${(_seq++) % 1000}';

  static Future<void> _encolar(Map<String, dynamic> fila) async {
    final uid = nuevoUid();
    final det = Map<String, dynamic>.from((fila['detalle'] as Map?) ?? const {});
    det['uid'] = uid;
    det['ts'] ??= DateTime.now().toUtc().toIso8601String();
    await _guardarEnCola('eventos', uid, {...fila, 'detalle': det, 'device_id': deviceId});
  }

  /// Advertencia de un guardia (tabla guard_warnings). Pasa por la cola.
  static Future<void> advertencia({
    required String guardId,
    required String buildingId,
    required String motivo,
    String? descripcion,
    String? registradoPor,
    DateTime? fecha,
  }) async {
    if (AppState.instance.soloLocal || !Sesion.vinculado) return;
    final uid = nuevoUid();
    await _guardarEnCola('guard_warnings', uid, {
      'uid': uid,
      'guard_id': guardId,
      'building_id': buildingId,
      'occurred_at': (fecha ?? DateTime.now()).toUtc().toIso8601String(),
      'reason': motivo,
      if (descripcion != null && descripcion.trim().isNotEmpty) 'description': descripcion.trim(),
      'created_by': registradoPor ?? AppState.instance.userNombre ?? (Sesion.esAdmin ? 'Administrador' : 'Guardia'),
    });
  }

  static Future<void> _guardarEnCola(String tabla, String uid, Map<String, dynamic> fila) async {
    final body = jsonEncode(fila);
    try {
      final db = await DB.instance.database;
      await db.insert('cola_nube', {
        'uid': uid,
        'tabla': tabla,
        'body': body,
        'intentos': 0,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      // Si la base local fallara, al menos intentarlo directo una vez.
      lastError = 'cola: $e';
      try {
        await http.post(Uri.parse('$_rest/$tabla'),
                headers: {...await _hdr(), 'Prefer': 'return=minimal'}, body: body)
            .timeout(const Duration(seconds: 12));
      } catch (_) {}
      return;
    }
    // No se espera: la pantalla sigue al instante.
    vaciarCola();
  }

  static bool _vaciando = false;

  /// Envía lo pendiente de la cola, en orden. Nunca corre dos veces a la vez.
  /// Se llama al crear un evento, al arrancar y en cada latido.
  static Future<void> vaciarCola() async {
    if (_vaciando || AppState.instance.soloLocal) return;
    _vaciando = true;
    try {
      final db = await DB.instance.database;
      while (true) {
        final filas = await db.query('cola_nube', orderBy: 'rowid', limit: 20);
        if (filas.isEmpty) break;
        for (final row in filas) {
          final uid = row['uid'] as String;
          final tabla = (row['tabla'] as String?) ?? 'eventos';
          final intentos = (row['intentos'] as int?) ?? 0;
          // Un reintento puede ser de un envío que SÍ llegó (se cortó la
          // respuesta): si ya está en la nube, no se vuelve a subir.
          if (intentos > 0) {
            final filtro = tabla == 'eventos' ? 'detalle->>uid' : 'uid';
            final q = await http
                .get(Uri.parse('$_rest/$tabla?select=id&$filtro=eq.${Uri.encodeComponent(uid)}&limit=1'),
                    headers: await _hdr())
                .timeout(const Duration(seconds: 12));
            if (q.statusCode < 300 && q.body.trim() != '[]') {
              await db.delete('cola_nube', where: 'uid=?', whereArgs: [uid]);
              continue;
            }
          }
          await db.rawUpdate('UPDATE cola_nube SET intentos = intentos + 1 WHERE uid=?', [uid]);
          final r = await http
              .post(Uri.parse('$_rest/$tabla'),
                  headers: {...await _hdr(), 'Prefer': 'return=minimal'}, body: row['body'] as String)
              .timeout(const Duration(seconds: 12));
          final c = r.statusCode;
          if (c < 300 || c == 409) {
            // 409 = ya existía (mismo uid): no se sube dos veces.
            await db.delete('cola_nube', where: 'uid=?', whereArgs: [uid]);
          } else if (c >= 400 && c < 500 && c != 401 && c != 403 && c != 408 && c != 429) {
            // Rechazo definitivo (fila inválida): se descarta para no trabar
            // la cola para siempre.
            lastError = '$tabla $c: ${r.body}';
            await db.delete('cola_nube', where: 'uid=?', whereArgs: [uid]);
          } else {
            // Sin permiso (sesión vencida / celular desvinculado) o servidor
            // con problemas: se conserva y se reintenta en el próximo latido.
            lastError = '$tabla $c: ${r.body}';
            return;
          }
        }
      }
    } catch (e) {
      lastError = 'cola: $e'; // sin señal: se reintenta después
    } finally {
      _vaciando = false;
    }
  }

  /// Eventos que todavía no llegaron a la nube.
  static Future<int> pendientes() async {
    try {
      final db = await DB.instance.database;
      final r = await db.rawQuery('SELECT COUNT(*) AS n FROM cola_nube');
      return (r.first['n'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// El admin publica la configuración (módulos) de un edificio para que los
  /// OTROS dispositivos de ese edificio la reciban. Se guarda como un evento
  /// 'Config' con el JSON de módulos. Pasa por la cola (no se pierde sin red).
  static Future<void> pushConfig(String edificio, String modulosJson) async {
    if (AppState.instance.soloLocal) return;
    await _encolar({
      'tipo': 'Config',
      'edificio': edificio,
      'guardia': AppState.instance.userNombre ?? 'Admin',
      'detalle': {'modulos': modulosJson},
      ..._contexto(edificio, null),
    });
  }

  /// Publica la contraseña de admin (hash + salt, NO texto plano) para que los
  /// otros dispositivos la adopten. Se guarda como evento 'AdminPass'.
  static Future<void> pushAdminPass(String usuario, String salt, String hash) async {
    if (AppState.instance.soloLocal) return;
    await _encolar({
      'tipo': 'AdminPass',
      'edificio': '*',
      'guardia': 'Admin',
      'detalle': {'usuario': usuario, 'salt': salt, 'hash': hash},
    });
  }

  /// Trae la última contraseña de admin publicada (o null).
  static Future<Map<String, dynamic>?> ultimaAdminPass() async {
    if (AppState.instance.soloLocal) return null;
    try {
      final params = ['select=created_at,detalle', 'tipo=eq.AdminPass', 'order=created_at.desc', 'limit=1'];
      final r = await http.get(Uri.parse('$_rest/eventos?${params.join('&')}'), headers: await _hdr())
          .timeout(const Duration(seconds: 12));
      if (r.statusCode >= 300) return null;
      final list = jsonDecode(r.body) as List;
      if (list.isEmpty) return null;
      final row = list.first as Map<String, dynamic>;
      final det = row['detalle'];
      if (det is! Map || det['salt'] == null || det['hash'] == null) return null;
      return {'created_at': row['created_at'], 'usuario': det['usuario'], 'salt': det['salt'], 'hash': det['hash']};
    } catch (e) {
      lastError = 'ultimaAdminPass: $e';
      return null;
    }
  }

  /// Trae la última configuración publicada para [edificio] (o null).
  /// Devuelve {created_at, modulos}.
  static Future<Map<String, dynamic>?> ultimaConfig(String edificio) async {
    if (AppState.instance.soloLocal) return null;
    try {
      final params = [
        'select=created_at,detalle',
        'tipo=eq.Config',
        'edificio=eq.${Uri.encodeComponent(edificio)}',
        'order=created_at.desc',
        'limit=1',
      ];
      final r = await http.get(Uri.parse('$_rest/eventos?${params.join('&')}'), headers: await _hdr())
          .timeout(const Duration(seconds: 12));
      if (r.statusCode >= 300) return null;
      final list = jsonDecode(r.body) as List;
      if (list.isEmpty) return null;
      final row = list.first as Map<String, dynamic>;
      final det = row['detalle'];
      final modulos = det is Map ? det['modulos'] : null;
      if (modulos == null) return null;
      return {'created_at': row['created_at'], 'modulos': modulos};
    } catch (e) {
      lastError = 'ultimaConfig: $e';
      return null;
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
        if (Sesion.vinculado && Estructura.idEdificio(s.edificioId) != null)
          'building_id': Sesion.esGuardia ? Sesion.buildingId : Estructura.idEdificio(s.edificioId),
        if (Sesion.esGuardia) 'unit_id': Sesion.unitId,
      };
      if (lat != null && lng != null) {
        body['lat'] = lat;
        body['lng'] = lng;
      }
      final uri = Uri.parse('$_rest/presencia?on_conflict=device_id');
      final headers = {...await _hdr(), 'Prefer': 'resolution=merge-duplicates,return=minimal'};
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
  /// [lanzar]: si falla, lanza la excepción en vez de devolver [] (para
  /// quien necesita distinguir "sin datos" de "no se pudo leer").
  static Future<List<Map<String, dynamic>>> eventos(
      {String? tipo, String? edificio, int limit = 120, bool lanzar = false}) async {
    if (AppState.instance.soloLocal) return [];
    try {
      final params = <String>['select=*', 'order=created_at.desc', 'limit=$limit'];
      if (tipo != null) params.add('tipo=eq.${Uri.encodeComponent(tipo)}');
      if (edificio != null) params.add(_filtroEdificio(edificio));
      final r = await http.get(Uri.parse('$_rest/eventos?${params.join('&')}'), headers: await _hdr())
          .timeout(const Duration(seconds: 25));
      if (r.statusCode >= 300) {
        lastError = 'eventos ${r.statusCode}: ${r.body}';
        if (lanzar) throw Exception(lastError);
        return [];
      }
      return List<Map<String, dynamic>>.from(jsonDecode(r.body) as List);
    } catch (e) {
      lastError = 'eventos: $e';
      if (lanzar) rethrow;
      return [];
    }
  }

  /// Hora REAL de un evento de la nube, en hora local: la que registró el
  /// celular (detalle.ts) o, en eventos viejos, la de subida (created_at).
  static DateTime? horaEvento(Map<String, dynamic> e) {
    final det = e['detalle'];
    final ts = det is Map ? det['ts'] : null;
    final t = DateTime.tryParse('${ts ?? e['created_at'] ?? ''}');
    return t?.toLocal();
  }

  /// Eventos de turno (ingreso, salida, 24/36 h y correcciones) de un mes
  /// ([mes] = cualquier día de ese mes; por defecto el actual), de TODOS los
  /// edificios o solo de [edificio].
  static Future<List<Map<String, dynamic>>> eventosTurnoMes(
      {DateTime? mes, String? edificio, bool lanzar = false}) async {
    if (AppState.instance.soloLocal) return [];
    try {
      final m = mes ?? DateTime.now();
      // 2 días antes (un turno de 36 h que termina en el mes empezó antes) y
      // 3 después (relevos del borde y eventos subidos tarde, sin señal).
      final desde = DateTime(m.year, m.month, 1).subtract(const Duration(days: 2)).toUtc().toIso8601String();
      final hasta = DateTime(m.year, m.month + 1, 1).add(const Duration(days: 3)).toUtc().toIso8601String();
      final ed = edificio != null ? [_filtroEdificio(edificio)] : const <String>[];
      final inval = '("Ingreso de turno","Salida de turno","Doblar turno")';
      final turnos = await _paginas([
        'tipo=in.${Uri.encodeComponent(inval)}',
        'created_at=gte.${Uri.encodeComponent(desde)}',
        'created_at=lt.${Uri.encodeComponent(hasta)}',
        ...ed,
      ]);
      // Las correcciones pueden hacerse semanas después: sin límite superior.
      final correcciones = await _paginas([
        'tipo=eq.${Uri.encodeComponent('Corrección de turno')}',
        'created_at=gte.${Uri.encodeComponent(desde)}',
        ...ed,
      ]);
      return [...turnos, ...correcciones];
    } catch (e) {
      lastError = 'turnos: $e';
      if (lanzar) rethrow;
      return [];
    }
  }

  /// Registros del mes que pertenecen a guardias (con guard_id) de un
  /// edificio: rondas, incidentes, visitas, etc. Solo columnas livianas.
  static Future<List<Map<String, dynamic>>> registrosGuardiasMes(String edificio, DateTime mes,
      {String? guardId, bool completos = false}) async {
    if (AppState.instance.soloLocal) return [];
    try {
      final desde = DateTime(mes.year, mes.month).toUtc().toIso8601String();
      final hasta = DateTime(mes.year, mes.month + 1).toUtc().toIso8601String();
      return await _paginas([
        guardId != null ? 'guard_id=eq.$guardId' : 'guard_id=not.is.null',
        _filtroEdificio(edificio),
        'created_at=gte.${Uri.encodeComponent(desde)}',
        'created_at=lt.${Uri.encodeComponent(hasta)}',
      ], select: completos ? '*' : 'id,tipo,guard_id,created_at');
    } catch (e) {
      lastError = 'registros: $e';
      return [];
    }
  }

  /// Lee TODAS las filas de una consulta, de a 1000 (el servidor no entrega
  /// más de 1000 por pedido: con un solo pedido se perdían los más nuevos).
  static Future<List<Map<String, dynamic>>> _paginas(List<String> filtros, {String select = '*'}) async {
    const pagina = 1000;
    final out = <Map<String, dynamic>>[];
    for (int offset = 0; offset < 50000; offset += pagina) {
      final params = ['select=$select', ...filtros, 'order=created_at.asc,id.asc', 'limit=$pagina', 'offset=$offset'];
      final r = await http
          .get(Uri.parse('$_rest/eventos?${params.join('&')}'), headers: await _hdr())
          .timeout(const Duration(seconds: 25));
      if (r.statusCode >= 300) throw Exception('turnos ${r.statusCode}: ${r.body}');
      final lote = List<Map<String, dynamic>>.from(jsonDecode(r.body) as List);
      out.addAll(lote);
      if (lote.length < pagina) break;
    }
    return out;
  }

  /// Borra eventos de la nube (para liberar espacio en Supabase). Si se pasa
  /// [edificio], solo borra los de ese edificio; sin edificio, borra todos.
  /// Borra de la nube los eventos con más de [dias] días (auto-limpieza para
  /// que el servidor no se llene). Se llama en cada arranque desde Retention.
  static Future<void> borrarEventosViejos(int dias) async {
    if (AppState.instance.soloLocal) return;
    try {
      final corte = DateTime.now().subtract(Duration(days: dias)).toUtc().toIso8601String();
      // Solo los de ESTE edificio (cada edificio tiene su propio periodo) y
      // nunca los de configuración/guardias: sin ellos un celular nuevo
      // quedaría sin módulos, sin guardias y sin contraseña de admin.
      final ed = AppState.instance.edificioId;
      await http
          .delete(
              Uri.parse('$_rest/eventos?created_at=lt.${Uri.encodeComponent(corte)}'
                  '&edificio=eq.${Uri.encodeComponent(ed)}&$_noSync'),
              headers: await _hdr())
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      lastError = 'borrarViejos: $e';
    }
  }

  static final String _noSync =
      'tipo=not.in.${Uri.encodeComponent('(Config,AdminPass,Guardia,GuardiaBaja)')}';

  static Future<bool> borrarEventos({String? edificio}) async {
    try {
      // PostgREST exige un filtro. Nunca se borran los eventos de
      // configuración y guardias (los necesitan los celulares nuevos).
      final filtro = edificio != null
          ? 'edificio=eq.${Uri.encodeComponent(edificio)}&$_noSync'
          : 'id=gte.0&$_noSync';
      final r = await http.delete(Uri.parse('$_rest/eventos?$filtro'), headers: await _hdr())
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

  /// Filtro por edificio. Un celular de guardia vinculado filtra por el id
  /// del edificio (lo que la base le permite ver); el admin, por el código,
  /// que incluye también el historial anterior a la migración.
  static String _filtroEdificio(String codigo) {
    if (Sesion.esGuardia && Sesion.buildingId != null) {
      return 'building_id=eq.${Sesion.buildingId}';
    }
    return 'edificio=eq.${Uri.encodeComponent(codigo)}';
  }

  /// Presencia de los celulares. Con [edificio], solo los de ese edificio
  /// (un guardia no descarga los datos ni la ubicación de otros edificios).
  static Future<List<Map<String, dynamic>>> presencia({String? edificio}) async {
    if (AppState.instance.soloLocal) return [];
    try {
      final f = edificio == null ? '' : '&${_filtroEdificio(edificio)}';
      final r = await http.get(Uri.parse('$_rest/presencia?select=*&order=last_seen.desc$f'), headers: await _hdr())
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
      // Si la foto aún se está enderezando en la cola, esperar (tope corto).
      await ImgUtil.esperarPendientes();
      final f = File(path);
      if (!await f.exists()) return null;
      // Miniatura NATIVA (rápida, poca memoria). Respaldo: Dart en isolate.
      Uint8List? small = await ImgUtil.miniaturaNube(path);
      if (small == null) {
        final raw = await f.readAsBytes();
        small = await compute(_comprimirFotoBytes, raw) ?? raw;
      }
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
              headers: _hAnon,
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
              headers: _hAnon,
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
              headers: {..._hAnon}, body: jsonEncode({'prefixes': rutas}))
          .timeout(const Duration(seconds: 25));
    } catch (_) {}
  }
}
