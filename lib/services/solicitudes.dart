import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_state.dart';
import 'cloud.dart';
import 'notifications_service.dart';

/// Solicitudes del guardia: ADELANTO de sueldo y DÍA LIBRE.
///
/// Todo viaja por la tabla `eventos` (sin cambiar la base):
/// - El guardia pide:      tipo 'Solicitud', detalle {clase: adelanto|libre, sid, motivo, fecha}
/// - Supervisión responde: tipo 'Respuesta', detalle {sid, estado: aprobado|rechazado}
/// - Adelanto aprobado → el guardia escribe lo que recibió:
///                         tipo 'Solicitud', detalle {clase: monto, sid, monto}
/// - Supervisión confirma: tipo 'Respuesta', detalle {sid, estado: confirmado|no_entregado, monto}
///   Solo lo CONFIRMADO cuenta como adelanto entregado.
class Solicitud {
  final String sid;
  final String clase; // adelanto | libre
  final String guardia;
  final String ci;
  final DateTime cuando;
  final String motivo;
  final String fecha; // día libre pedido (yyyy-MM-dd)
  String estado = 'pendiente'; // pendiente | aprobado | rechazado | por_confirmar | confirmado | no_entregado
  double? montoGuardia; // lo que escribió el guardia
  double? montoFinal; // lo que confirmó supervisión
  String nota = '';
  bool enviado = true; // false = todavía en la cola del celular

  Solicitud({
    required this.sid,
    required this.clase,
    required this.guardia,
    required this.ci,
    required this.cuando,
    this.motivo = '',
    this.fecha = '',
  });

  bool get esAdelanto => clase == 'adelanto';

  String get titulo => esAdelanto ? 'Adelanto' : 'Día libre${fecha.isNotEmpty ? ' · ${Solicitudes.fechaTxt(fecha)}' : ''}';

  String get estadoTxt {
    switch (estado) {
      case 'aprobado':
        return esAdelanto ? 'Aprobado: escribe el monto que recibiste' : 'Aprobado';
      case 'rechazado':
        return 'No aprobado';
      case 'por_confirmar':
        return 'Monto enviado (Bs ${Solicitudes.bs(montoGuardia)}): falta que supervisión lo confirme';
      case 'confirmado':
        return 'Confirmado: Bs ${Solicitudes.bs(montoFinal ?? montoGuardia)}';
      case 'no_entregado':
        return 'Supervisión no confirmó este adelanto';
      default:
        return enviado ? 'Esperando respuesta de supervisión' : 'Por enviar (sin señal se envía al volver la conexión)';
    }
  }
}

/// Guardia que pide (no tiene que ser el que está de turno en el celular).
class Quien {
  final String nombre, ci;
  const Quien(this.nombre, this.ci);
}

class Solicitudes {
  static String bs(double? v) {
    if (v == null) return '-';
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  }

  static String fechaTxt(String ymd) {
    final d = DateTime.tryParse(ymd);
    return d == null ? ymd : DateFormat('EEE dd/MM', 'es').format(d);
  }

  static double? _num(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}'.replaceAll(',', '.'));

  static String _enc(String s) => Uri.encodeComponent(s);

  static const _pendKey = 'solicitudes_por_enviar';

  // ---------------------------------------------------------------------------
  // ENVIAR
  // ---------------------------------------------------------------------------

  static Future<void> pedirAdelanto(Quien q, String motivo) => _pedir(q, {'clase': 'adelanto', 'motivo': motivo});

  static Future<void> pedirLibre(Quien q, DateTime dia, String motivo) =>
      _pedir(q, {'clase': 'libre', 'fecha': DateFormat('yyyy-MM-dd').format(dia), 'motivo': motivo});

  /// El evento va a nombre de [q] (su CI reemplaza al del guardia de turno).
  static Future<void> _evento(Quien q, Map<String, dynamic> d) =>
      Cloud.evento('Solicitud', guardia: q.nombre, detalle: {...d, if (q.ci.isNotEmpty) 'guard_ci': q.ci});

  static Future<void> _pedir(Quien q, Map<String, dynamic> det) async {
    final sid = Cloud.nuevoUid();
    final d = {...det, 'sid': sid};
    await _evento(q, d);
    // Se muestra en la lista aunque todavía no haya subido.
    final prefs = await SharedPreferences.getInstance();
    final l = prefs.getStringList(_pendKey) ?? [];
    l.add(jsonEncode({...d, 'guardia': q.nombre, 'ci': q.ci, 'ts': DateTime.now().toIso8601String()}));
    await prefs.setStringList(_pendKey, l.length > 20 ? l.sublist(l.length - 20) : l);
  }

  static Future<void> enviarMonto(Quien q, Solicitud x, double monto) =>
      _evento(q, {'clase': 'monto', 'sid': x.sid, 'monto': monto});

  // ---------------------------------------------------------------------------
  // LEER (las del guardia de turno)
  // ---------------------------------------------------------------------------

  /// Solicitudes de los últimos 120 días de [q], la más nueva primero.
  static Future<List<Solicitud>> delGuardia(Quien q) async {
    final s = AppState.instance;
    final ed = _enc(s.edificioId);
    final ci = q.ci.trim();
    final desde = _enc(DateTime.now().subtract(const Duration(days: 120)).toUtc().toIso8601String());
    final quien = ci.isNotEmpty
        ? 'detalle->>guard_ci=eq.${_enc(ci)}'
        : 'guardia=eq.${_enc(q.nombre)}';
    final pedidos = await Cloud.leer('eventos?select=guardia,detalle,created_at&tipo=eq.Solicitud'
        '&edificio=eq.$ed&$quien&created_at=gte.$desde&order=created_at.desc&limit=300');
    final lista = <String, Solicitud>{};
    final montos = <String, Map>{};
    for (final e in pedidos) {
      final d = e['detalle'];
      if (d is! Map) continue;
      final sid = '${d['sid'] ?? ''}';
      if (sid.isEmpty) continue;
      final clase = '${d['clase'] ?? ''}';
      if (clase == 'monto') {
        montos.putIfAbsent(sid, () => d); // el más nuevo
        continue;
      }
      if (clase != 'adelanto' && clase != 'libre') continue;
      lista[sid] = Solicitud(
        sid: sid,
        clase: clase,
        guardia: '${e['guardia'] ?? ''}',
        ci: '${d['guard_ci'] ?? ''}',
        cuando: Cloud.horaEvento(e) ?? DateTime.now(),
        motivo: '${d['motivo'] ?? ''}',
        fecha: '${d['fecha'] ?? ''}',
      );
    }
    // Las que siguen en la cola de este celular.
    final prefs = await SharedPreferences.getInstance();
    final pend = prefs.getStringList(_pendKey) ?? [];
    final quedan = <String>[];
    for (final txt in pend) {
      try {
        final d = jsonDecode(txt) as Map;
        final sid = '${d['sid']}';
        if (lista.containsKey(sid)) continue; // ya subió
        final cuando = DateTime.tryParse('${d['ts']}') ?? DateTime.now();
        if (DateTime.now().difference(cuando).inDays > 7) continue;
        quedan.add(txt);
        final mio = ci.isNotEmpty ? d['ci'] == ci : d['guardia'] == q.nombre;
        if (!mio) continue;
        lista[sid] = (Solicitud(
          sid: sid,
          clase: '${d['clase']}',
          guardia: '${d['guardia']}',
          ci: '${d['ci']}',
          cuando: cuando,
          motivo: '${d['motivo'] ?? ''}',
          fecha: '${d['fecha'] ?? ''}',
        )..enviado = false);
      } catch (_) {}
    }
    await prefs.setStringList(_pendKey, quedan);
    if (lista.isEmpty) return [];
    final resp = await Cloud.leer('eventos?select=detalle,created_at&tipo=eq.Respuesta&edificio=eq.$ed'
        '&created_at=gte.$desde&order=created_at.asc&limit=1000');
    _aplicar(lista, montos, resp);
    final out = lista.values.toList()..sort((a, b) => b.cuando.compareTo(a.cuando));
    return out;
  }

  static void _aplicar(Map<String, Solicitud> lista, Map<String, Map> montos, List<Map<String, dynamic>> resp) {
    for (final x in lista.values) {
      final m = montos[x.sid];
      if (m != null) x.montoGuardia = _num(m['monto']);
    }
    // Respuestas en orden: la última manda.
    for (final r in resp) {
      final d = r['detalle'];
      if (d is! Map) continue;
      final x = lista[d['sid']];
      if (x == null) continue;
      final est = '${d['estado'] ?? ''}';
      if (!const ['aprobado', 'rechazado', 'confirmado', 'no_entregado'].contains(est)) continue;
      x.estado = est;
      x.nota = '${d['nota'] ?? ''}';
      if (est == 'confirmado') x.montoFinal = _num(d['monto']) ?? x.montoGuardia;
    }
    for (final x in lista.values) {
      if (x.esAdelanto && x.estado == 'aprobado' && x.montoGuardia != null) x.estado = 'por_confirmar';
    }
  }

  // ---------------------------------------------------------------------------
  // AVISOS EN EL CELULAR (desde el latido)
  // ---------------------------------------------------------------------------

  static DateTime? _ultimaRevision;

  /// Muestra una notificación por cada respuesta nueva de supervisión en este
  /// edificio. Como máximo cada 2 minutos.
  static Future<void> revisarRespuestas() async {
    final s = AppState.instance;
    if (s.soloLocal) return;
    final ahora = DateTime.now();
    if (_ultimaRevision != null && ahora.difference(_ultimaRevision!) < const Duration(minutes: 2)) return;
    _ultimaRevision = ahora;
    try {
      final prefs = await SharedPreferences.getInstance();
      final clave = 'resp_vista_${s.edificioId}';
      final visto = prefs.getString(clave);
      if (visto == null) {
        // Primera vez en este celular: no se avisa lo viejo.
        await prefs.setString(clave, ahora.toUtc().toIso8601String());
        return;
      }
      final r = await Cloud.leer('eventos?select=detalle,created_at&tipo=eq.Respuesta'
          '&edificio=eq.${_enc(s.edificioId)}&created_at=gt.${_enc(visto)}&order=created_at.asc&limit=50');
      if (r.isEmpty) return;
      int n = 0;
      for (final e in r) {
        final d = e['detalle'];
        if (d is! Map) continue;
        final quien = '${d['guardia'] ?? ''}'.trim();
        final adel = d['clase'] != 'libre';
        final dia = '${d['fecha'] ?? ''}';
        String titulo, cuerpo;
        switch ('${d['estado']}') {
          case 'aprobado':
            titulo = adel ? 'Adelanto aprobado' : 'Día libre aprobado';
            cuerpo = adel
                ? '$quien: entra a Solicitudes y escribe el monto que recibiste.'
                : '$quien: tu día libre${dia.isNotEmpty ? ' del ${fechaTxt(dia)}' : ''} está aprobado.';
            break;
          case 'rechazado':
            titulo = adel ? 'Adelanto no aprobado' : 'Día libre no aprobado';
            cuerpo = '$quien: supervisión no aprobó tu solicitud.';
            break;
          case 'confirmado':
            titulo = 'Adelanto confirmado';
            cuerpo = '$quien: Bs ${bs(_num(d['monto']))}.';
            break;
          case 'no_entregado':
            titulo = 'Adelanto no confirmado';
            cuerpo = '$quien: supervisión no confirmó el monto.';
            break;
          default:
            continue;
        }
        await Notificaciones.mostrarAviso(titulo, cuerpo, id: 5000 + (ahora.millisecondsSinceEpoch ~/ 1000 + n++) % 4000);
      }
      await prefs.setString(clave, '${r.last['created_at']}');
    } catch (_) {}
  }
}
