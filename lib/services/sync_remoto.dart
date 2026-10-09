import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import '../db/database_helper.dart';
import 'app_state.dart';
import 'cloud.dart';
import 'device_context.dart';
import 'notifications_service.dart';

/// Configuración y datos del edificio manejados desde el MONITOR WEB.
/// - "Equipo": cada celular publica sus ajustes actuales (la web los muestra).
/// - "AjustesEquipo": la web manda ajustes para UN celular (por su device_id).
/// - "Datos": listas completas del edificio (propietarios, vehículos...). La
///   última publicada manda; un cambio hecho en el celular se publica entero.
class SyncRemoto {
  static const version = '12.7';
  static const clases = ['propietarios', 'residentes', 'vehiculos', 'contactos', 'normativas', 'puntos_control', 'recurrentes'];

  /// Columnas que viajan por la nube (las fotos locales no viajan).
  static const Map<String, List<String>> _cols = {
    'propietarios': ['id', 'torre', 'depto', 'copropietario', 'telefono', 'inquilino', 'telefono_inq', 'mascota',
      'nombre_mascota', 'nro_parqueo', 'vehiculo', 'placa', 'observaciones'],
    'residentes': ['depto', 'nombre', 'parentesco', 'celular', 'observaciones'],
    'vehiculos': ['depto', 'placa', 'vehiculo', 'marca', 'modelo', 'color', 'propietario', 'nro_parqueo', 'telefono',
      'observaciones'],
    'contactos': ['nombre', 'telefono'],
    'normativas': ['nombre'],
    'puntos_control': ['nombre', 'codigo'],
    'recurrentes': ['nombre', 'ci', 'depto', 'motivo', 'placa'],
  };

  static DateTime? _ultimaDatos;
  static bool _datosEnCurso = false;

  static String _enc(String s) => Uri.encodeComponent(s);

  // ---------------------------------------------------------------------------
  // AJUSTES DEL CELULAR
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> ajustesActuales() {
    final s = AppState.instance;
    return {
      'bloque': s.bloque,
      'ronda_fotos': s.rondaFotos,
      'ronda_horas': s.rondaHoras,
      'notif_rondas': s.notifRondas,
      'alarma_candados': s.alarmaCandados,
      'control_uniforme': s.controlUniforme,
      'turno_ingreso': s.turnoIngreso,
      'turno_salida': s.turnoSalida,
      'retencion_dias': s.retencionDias,
      'camara_nativa': s.camaraNativa,
      'notif_metodo': s.notifMetodo,
      'admin_whatsapp': s.adminWhatsapp,
      'admin_email': s.adminEmail,
    };
  }

  /// Publica los ajustes de este celular si cambiaron (o cada 12 h).
  static Future<void> reportarEquipo({bool forzar = false}) async {
    final s = AppState.instance;
    if (s.soloLocal) return;
    try {
      final modelo = await DeviceContext.dispositivo();
      final aj = ajustesActuales();
      final firma = jsonEncode({'ed': s.edificioId, 'm': modelo, 'a': aj, 'v': version});
      final prefs = await SharedPreferences.getInstance();
      final cuando = DateTime.tryParse(prefs.getString('equipo_at') ?? '');
      final viejo = cuando == null || DateTime.now().difference(cuando) > const Duration(hours: 12);
      if (!forzar && prefs.getString('equipo_firma') == firma && !viejo) return;
      await Cloud.evento('Equipo', guardia: 'Sistema', detalle: {
        'device_id': Cloud.deviceId,
        'modelo': modelo,
        'version': version,
        'ajustes': aj,
      });
      await prefs.setString('equipo_firma', firma);
      await prefs.setString('equipo_at', DateTime.now().toIso8601String());
      // Los reportes viejos de este celular ya no sirven.
      final corte = DateTime.now().subtract(const Duration(days: 2)).toUtc().toIso8601String();
      await Cloud.borrarDonde('tipo=eq.Equipo&detalle->>device_id=eq.${_enc(Cloud.deviceId)}'
          '&created_at=lt.${_enc(corte)}');
    } catch (_) {}
  }

  /// Aplica los ajustes que mandó la web para ESTE celular. true si cambió algo.
  static Future<bool> aplicarAjustes() async {
    final s = AppState.instance;
    if (s.soloLocal) return false;
    try {
      final r = await Cloud.leer('eventos?select=created_at,detalle&tipo=eq.AjustesEquipo'
          '&edificio=eq.${_enc(s.edificioId)}&detalle->>device_id=eq.${_enc(Cloud.deviceId)}'
          '&order=created_at.desc&limit=1');
      if (r.isEmpty) return false;
      final det = r.first['detalle'];
      if (det is! Map) return false;
      final ver = '${det['version'] ?? det['uid'] ?? r.first['created_at']}';
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString('ajustes_ver') == ver) return false;
      final a = det['ajustes'];
      if (a is Map) await _aplicarAjustes(a);
      await prefs.setString('ajustes_ver', ver);
      try {
        await Notificaciones.programarRecordatorios();
      } catch (_) {}
      await reportarEquipo(forzar: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  static int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));
  static bool? _bool(Object? v) => v is bool ? v : null;
  static String? _txt(Map a, String k) => a.containsKey(k) ? '${a[k] ?? ''}'.trim() : null;

  static Future<void> _aplicarAjustes(Map a) async {
    final s = AppState.instance;
    final bloque = _txt(a, 'bloque');
    if (bloque != null) await s.setBloque(bloque);
    await s.setOperacion(
      rondaFotos: _int(a['ronda_fotos']),
      retencionDias: _int(a['retencion_dias']),
      turnoIngreso: _txt(a, 'turno_ingreso'),
      turnoSalida: _txt(a, 'turno_salida'),
    );
    await s.setRecordatorios(
      rondas: _bool(a['notif_rondas']),
      candados: _bool(a['alarma_candados']),
      uniforme: _bool(a['control_uniforme']),
      rondaHoras: _int(a['ronda_horas']),
    );
    final cam = _bool(a['camara_nativa']);
    if (cam != null) await s.setCamaraNativa(cam);
    final metodo = _txt(a, 'notif_metodo');
    await s.setNotifConfig(
      metodo: (metodo != null && const ['whatsapp', 'email', 'ambos', 'ninguno'].contains(metodo)) ? metodo : null,
      whatsapp: _txt(a, 'admin_whatsapp'),
      email: _txt(a, 'admin_email'),
    );
  }

  // ---------------------------------------------------------------------------
  // DATOS DEL EDIFICIO (propietarios, residentes, vehículos, contactos...)
  // ---------------------------------------------------------------------------

  static String _clave(String ed, String clase) => 'datos_${ed}_$clase';

  /// Trae lo que publicó la web (o otro celular). Si la nube todavía no tiene
  /// una lista, sube la de este celular como punto de partida.
  static Future<bool> sincronizarDatos({bool forzar = false}) async {
    final s = AppState.instance;
    if (s.soloLocal || _datosEnCurso) return false;
    final ahora = DateTime.now();
    if (!forzar && _ultimaDatos != null && ahora.difference(_ultimaDatos!) < const Duration(minutes: 5)) return false;
    _datosEnCurso = true;
    bool cambio = false;
    try {
      final ed = s.edificioId;
      final prefs = await SharedPreferences.getInstance();
      for (final clase in clases) {
        final r = await Cloud.leer('eventos?select=created_at,detalle&tipo=eq.Datos&edificio=eq.${_enc(ed)}'
            '&detalle->>clase=eq.$clase&order=created_at.desc&limit=1');
        final key = _clave(ed, clase);
        if (r.isEmpty) {
          if (prefs.getString(key) == null) {
            final db = await DB.instance.database;
            final n = Sqflite.firstIntValue(
                    await db.rawQuery('SELECT COUNT(*) FROM $clase WHERE edificio=?', [ed])) ??
                0;
            if (n > 0) await publicarDatos(clase);
          }
          continue;
        }
        final det = r.first['detalle'];
        if (det is! Map) continue;
        final ver = '${det['version'] ?? det['uid'] ?? r.first['created_at']}';
        if (prefs.getString(key) == ver) continue;
        final filas = det['filas'];
        if (filas is! List) continue;
        await _aplicarDatos(clase, ed, filas);
        await prefs.setString(key, ver);
        cambio = true;
      }
      _ultimaDatos = ahora;
    } catch (_) {
    } finally {
      _datosEnCurso = false;
    }
    return cambio;
  }

  /// Publica la lista COMPLETA de [clase] de este celular (tras un cambio local).
  static Future<void> publicarDatos(String clase) async {
    final s = AppState.instance;
    if (s.soloLocal || !_cols.containsKey(clase)) return;
    try {
      final ed = s.edificioId;
      final filas = await _filasLocales(clase, ed);
      final ver = '${Cloud.deviceId}_${DateTime.now().microsecondsSinceEpoch}';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_clave(ed, clase), ver); // lo propio no se vuelve a aplicar
      await Cloud.evento('Datos', guardia: 'Sistema', detalle: {
        'clase': clase,
        'version': ver,
        'origen': 'app',
        'filas': filas,
      });
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> _filasLocales(String clase, String ed) async {
    final db = await DB.instance.database;
    final rows = await db.query(clase, where: 'edificio=?', whereArgs: [ed]);
    final prefs = await SharedPreferences.getInstance();
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final m = <String, dynamic>{};
      for (final c in _cols[clase]!) {
        final v = r[c];
        if (v != null && '$v'.trim().isNotEmpty) m[c] = '$v';
      }
      if (clase == 'normativas') {
        final path = '${r['pdf_path'] ?? ''}';
        var url = '';
        if (path.startsWith('http')) {
          url = path;
        } else if (path.isNotEmpty) {
          url = prefs.getString('norm_url_$path') ?? '';
          if (url.isEmpty && File(path).existsSync()) {
            url = await Cloud.subirArchivo(path) ?? '';
            if (url.isNotEmpty) await prefs.setString('norm_url_$path', url);
          }
        }
        if (url.isNotEmpty) m['url'] = url;
      }
      out.add(m);
    }
    return out;
  }

  static String _k(String clase, Map r) => clase == 'vehiculos'
      ? '${r['placa'] ?? ''}|${r['depto'] ?? ''}'.toLowerCase()
      : clase == 'recurrentes'
          ? '${r['nombre'] ?? ''}'.trim().toLowerCase()
          : '${r['depto'] ?? ''}|${r['nombre'] ?? ''}'.toLowerCase();

  static Future<void> _aplicarDatos(String clase, String ed, List filas) async {
    final db = await DB.instance.database;
    final prefs = await SharedPreferences.getInstance();
    // Las fotos locales (vehículos, residentes) se conservan si el registro sigue.
    final fotos = <String, Object?>{};
    // Recurrentes: se conserva si está DENTRO ahora (y su visita abierta).
    final estado = <String, Map<String, Object?>>{};
    if (clase == 'vehiculos' || clase == 'residentes' || clase == 'recurrentes') {
      for (final v in await db.query(clase, where: 'edificio=?', whereArgs: [ed])) {
        if (v['foto'] != null) fotos[_k(clase, v)] = v['foto'];
        if (clase == 'recurrentes') {
          estado[_k(clase, v)] = {'dentro': v['dentro'], 'visita_abierta': v['visita_abierta'], 'created_at': v['created_at']};
        }
      }
    }
    // Normativas: si el archivo lo subió este celular, se sigue usando el local.
    final localDe = <String, String>{};
    for (final k in prefs.getKeys()) {
      if (k.startsWith('norm_url_')) {
        final u = prefs.getString(k);
        if (u != null) localDe[u] = k.substring('norm_url_'.length);
      }
    }
    await db.transaction((txn) async {
      await txn.delete(clase, where: 'edificio=?', whereArgs: [ed]);
      final b = txn.batch();
      int i = 0;
      for (final f in filas) {
        if (f is! Map) continue;
        final row = <String, Object?>{'edificio': ed};
        for (final c in _cols[clase]!) {
          final v = f[c];
          row[c] = v == null ? null : '$v';
        }
        if (clase == 'propietarios') {
          final id = '${f['id'] ?? ''}'.trim();
          row['id'] = id.isEmpty ? 'web_${ed}_$i' : id;
        }
        if (clase == 'normativas') {
          final url = '${f['url'] ?? ''}';
          final local = localDe[url];
          row['pdf_path'] = (local != null && File(local).existsSync()) ? local : url;
        }
        if (clase == 'puntos_control') row['created_at'] = DateTime.now().toIso8601String();
        if (clase == 'recurrentes') {
          final e = estado[_k(clase, row)];
          row['dentro'] = e?['dentro'] ?? 0;
          row['visita_abierta'] = e?['visita_abierta'];
          row['created_at'] = e?['created_at'] ?? DateTime.now().toIso8601String();
        }
        final foto = fotos[_k(clase, row)];
        if (foto != null) row['foto'] = foto;
        b.insert(clase, row, conflictAlgorithm: ConflictAlgorithm.replace);
        i++;
      }
      await b.commit(noResult: true);
    });
  }

  /// Documento de normativas guardado en la nube: se descarga una vez y queda
  /// en el celular. Devuelve la ruta local o null (sin internet).
  static Future<String?> descargar(String url) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final carpeta = Directory(p.join(dir.path, 'normativas'));
      if (!await carpeta.exists()) await carpeta.create(recursive: true);
      var ext = p.extension(Uri.parse(url).path).toLowerCase();
      if (ext.isEmpty || ext.length > 5) ext = '.pdf';
      final destino = File(p.join(carpeta.path, 'web_${url.hashCode.toUnsigned(32)}$ext'));
      if (await destino.exists() && await destino.length() > 0) return destino.path;
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
      if (r.statusCode >= 300) return null;
      await destino.writeAsBytes(r.bodyBytes);
      return destino.path;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // EDIFICIOS creados en otro celular o desde el monitor web
  // ---------------------------------------------------------------------------

  static DateTime? _ultimaEdificios;

  /// Agrega a este celular los edificios que existen en la nube (tienen
  /// configuración publicada) y todavía no están aquí. No borra ninguno.
  static Future<bool> sincronizarEdificios({bool forzar = false}) async {
    if (AppState.instance.soloLocal) return false;
    final ahora = DateTime.now();
    if (!forzar && _ultimaEdificios != null && ahora.difference(_ultimaEdificios!) < const Duration(minutes: 10)) {
      return false;
    }
    _ultimaEdificios = ahora;
    try {
      final r = await Cloud.leer('eventos?select=edificio,detalle&tipo=eq.Config&order=created_at.desc&limit=2000');
      final db = await DB.instance.database;
      final locales = {for (final e in await db.query('edificios', columns: ['id'])) '${e['id']}'.toLowerCase()};
      final nuevos = <String, String>{}; // edificio -> modulos (el más reciente)
      for (final row in r) {
        final ed = '${row['edificio'] ?? ''}'.trim();
        if (ed.isEmpty || ed == '*' || ed.startsWith('__') || locales.contains(ed.toLowerCase()) || nuevos.containsKey(ed)) continue;
        final det = row['detalle'];
        final m = det is Map ? det['modulos'] : null;
        final txt = m is String ? m : (m is Map ? jsonEncode(m) : '');
        try {
          if (jsonDecode(txt) is! Map) continue;
        } catch (_) {
          continue;
        }
        nuevos[ed] = txt;
      }
      for (final e in nuevos.entries) {
        final mod = jsonDecode(e.value) as Map;
        final torres = mod['torres'] is List ? [for (final t in mod['torres'] as List) '$t'] : <String>[];
        await db.insert('edificios', {
          'id': e.key,
          'nombre': e.key,
          'torres': jsonEncode(torres),
          'modulos': e.value,
          'cant_deptos': 0,
          'cant_pisos': 0,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      return nuevos.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Todo junto (latido): ajustes de la web, reporte del equipo y datos.
  static Future<bool> latido() async {
    final e = await sincronizarEdificios();
    final a = await aplicarAjustes();
    await reportarEquipo();
    final d = await sincronizarDatos();
    return e || a || d;
  }
}
