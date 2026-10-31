import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'app_state.dart';
import 'cloud.dart';
import 'notifications_service.dart';
import 'turnos.dart';
import '../screens/presencia_screen.dart';

/// Una verificación programada de la noche.
class Verificacion {
  final String pid; // identificador único
  final DateTime t; // hora programada (= hora en que suena la alarma)
  final int nid; // id de la notificación
  bool hecha;
  Verificacion(this.pid, this.t, this.nid, {this.hecha = false});

  Map<String, dynamic> toJson() => {'pid': pid, 't': t.toIso8601String(), 'nid': nid, 'hecha': hecha};
  static Verificacion? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = DateTime.tryParse('${j['t']}');
    if (t == null) return null;
    return Verificacion('${j['pid']}', t, (j['nid'] as num?)?.toInt() ?? 6000, hecha: j['hecha'] == true);
  }
}

/// CONTROL DE PRESENCIA NOCTURNA.
///
/// Supervisión lo activa por edificio desde el monitor (Celulares
/// corporativos > Ajustes > Control nocturno): horario (por defecto 00:00 a
/// 06:00, hora de Bolivia), cuántas verificaciones por noche, separación mínima
/// entre ellas y tiempo máximo de respuesta (8 min).
///
/// Con un turno abierto, este celular sortea ANTES de la noche los horarios
/// (aleatorios, con la separación mínima) y los programa como ALARMAS EXACTAS
/// del sistema (AlarmManager, siguen aunque se cierre la app y se reprograman
/// al reiniciar el celular). El guardia no ve los horarios ni cuántas faltan.
/// El plan se sube a la nube (tipo 'PresenciaPlan') para que supervisión vea
/// las próximas verificaciones y para que el aviso por correo de los 8 minutos
/// funcione aunque el celular quede apagado o sin internet.
///
/// Cuando suena, se abre la pantalla de verificación (firma + foto frontal).
/// La respuesta se guarda como evento 'Presencia' (por la cola: sin internet
/// se envía después, sin duplicarse).
class Presencia {
  static final nav = GlobalKey<NavigatorState>();
  static const _canal = MethodChannel('osiris/alarma');
  static const _kPlan = 'presencia_plan';

  static Map<String, dynamic> get _m => AppState.instance.modulos;
  static bool get activa => _m['presencia_on'] == true && !AppState.instance.soloLocal;
  static String get desde => _hhmm(_m['presencia_desde'], '00:00');
  static String get hasta => _hhmm(_m['presencia_hasta'], '06:00');
  static int get cantidad => _int(_m['presencia_n'], 3, 1, 12);
  static int get separacion => _int(_m['presencia_sep'], 40, 5, 240); // minutos
  static int get maxMin => _int(_m['presencia_max'], 8, 1, 60); // minutos

  static String _hhmm(Object? v, String def) {
    final s = '${v ?? ''}'.trim();
    return RegExp(r'^\d{2}:\d{2}$').hasMatch(s) ? s : def;
  }

  static int _int(Object? v, int def, int min, int max) {
    final n = int.tryParse('${v ?? ''}');
    return n == null ? def : n.clamp(min, max);
  }

  static int _minDe(String hhmm) => int.parse(hhmm.substring(0, 2)) * 60 + int.parse(hhmm.substring(3, 5));

  /// Ventana (inicio, fin) de la noche que todavía no terminó.
  static (DateTime, DateTime, String) _ventana(DateTime ahora) {
    final d = _minDe(desde), h = _minDe(hasta);
    for (int dia = -1; dia <= 1; dia++) {
      final base = DateTime(ahora.year, ahora.month, ahora.day + dia);
      final ini = base.add(Duration(minutes: d));
      var fin = base.add(Duration(minutes: h));
      if (!fin.isAfter(ini)) fin = fin.add(const Duration(days: 1));
      if (fin.isAfter(ahora)) {
        final noche = '${ini.year}-${ini.month.toString().padLeft(2, '0')}-${ini.day.toString().padLeft(2, '0')}';
        return (ini, fin, noche);
      }
    }
    final ini = DateTime(ahora.year, ahora.month, ahora.day + 1).add(Duration(minutes: d));
    return (ini, ini.add(const Duration(hours: 6)), '');
  }

  /// Horarios aleatorios entre [ini] y [fin] con separación mínima.
  /// Usa el generador SEGURO del sistema: no se repiten patrones de una noche a otra.
  static List<DateTime> _sortear(DateTime ini, DateTime fin, int n, int sepMin) {
    final r = Random.secure();
    final largo = fin.difference(ini).inSeconds;
    if (largo <= 0) return [];
    final sep = sepMin * 60;
    // Cuántas caben realmente con la separación pedida.
    final caben = max(1, min(n, largo ~/ max(1, sep) + 1));
    for (int intento = 0; intento < 3000; intento++) {
      final xs = List.generate(caben, (_) => r.nextInt(largo))..sort();
      var ok = true;
      for (int i = 1; i < xs.length; i++) {
        if (xs[i] - xs[i - 1] < sep) {
          ok = false;
          break;
        }
      }
      if (ok) return xs.map((s) => ini.add(Duration(seconds: s))).toList();
    }
    // Respaldo: tramos iguales con un desplazamiento aleatorio dentro de cada uno.
    final tramo = largo ~/ caben;
    return List.generate(caben, (i) => ini.add(Duration(seconds: i * tramo + r.nextInt(max(1, tramo - sep ~/ 2)))));
  }

  static Future<Map<String, dynamic>?> _leerPlan() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final j = jsonDecode(prefs.getString(_kPlan) ?? '');
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _guardarPlan(Map<String, dynamic>? p) async {
    final prefs = await SharedPreferences.getInstance();
    if (p == null) {
      await prefs.remove(_kPlan);
    } else {
      await prefs.setString(_kPlan, jsonEncode(p));
    }
  }

  static List<Verificacion> _items(Map<String, dynamic>? p) =>
      ((p?['items'] as List?) ?? const []).map(Verificacion.fromJson).whereType<Verificacion>().toList();

  static bool _planificando = false;

  /// Arma (o mantiene) el plan de la noche y programa las alarmas.
  /// Se llama al arrancar, en cada latido, al iniciar/finalizar turno y cuando
  /// supervisión cambia la configuración.
  static Future<void> planificar() async {
    if (_planificando) return;
    _planificando = true;
    try {
      final s = AppState.instance;
      final plan = await _leerPlan();
      if (!activa || s.turnoActivoId == null) {
        // Sin control o sin turno: se quitan las alarmas que falten sonar
        // (las que ya sonaron y no se respondieron se mantienen hasta responder).
        if (plan != null) {
          final ahora = DateTime.now();
          final items = _items(plan);
          for (final v in items) {
            if (!v.hecha && v.t.isAfter(ahora)) {
              try { await Notificaciones.plugin.cancel(v.nid); } catch (_) {}
            }
          }
          final quedan = items.where((v) => !v.hecha && !v.t.isAfter(ahora)).toList();
          if (quedan.isEmpty) {
            await _guardarPlan(null);
          } else {
            plan['items'] = quedan.map((v) => v.toJson()).toList();
            await _guardarPlan(plan);
          }
        }
        return;
      }
      final ahora = DateTime.now();
      final (ini, fin, noche) = _ventana(ahora);
      if (noche.isEmpty) return;
      final ref = Turnos.ref(Cloud.deviceId, s.turnoActivoId);
      final firma = '$noche|$ref|$desde|$hasta|$cantidad|$separacion';
      if (plan != null && plan['firma'] == firma) {
        // Ya planificada: solo se asegura que estén programadas y subidas.
        await _programar(_items(plan));
        if (plan['subido'] != true) await _subirPlan(plan);
        return;
      }
      // Plan nuevo (otra noche, otro turno o cambió la configuración).
      // Se conservan las ya sonadas sin responder del plan anterior.
      final previas = _items(plan)
          .where((v) => !v.hecha && !v.t.isAfter(ahora) && ahora.difference(v.t) < const Duration(hours: 12))
          .toList();
      for (final v in _items(plan)) {
        if (!v.hecha && v.t.isAfter(ahora)) {
          try { await Notificaciones.plugin.cancel(v.nid); } catch (_) {}
        }
      }
      // Si la noche ya empezó, solo desde ahora (+2 min) en adelante.
      final desdeT = ini.isAfter(ahora) ? ini : ahora.add(const Duration(minutes: 2));
      final total = fin.difference(ini).inMinutes;
      final resto = fin.difference(desdeT).inMinutes;
      var n = cantidad;
      if (resto < total) n = max(1, (cantidad * resto / max(1, total)).round());
      final horas = resto > 1 ? _sortear(desdeT, fin, n, separacion) : <DateTime>[];
      final r = Random.secure();
      final usados = previas.map((v) => v.nid).toSet();
      int sigNid() {
        for (int i = 6000; i < 6100; i++) {
          if (!usados.contains(i)) {
            usados.add(i);
            return i;
          }
        }
        return 6099;
      }

      final nuevas = [
        for (final t in horas)
          Verificacion('${Cloud.deviceId}_${t.millisecondsSinceEpoch}_${r.nextInt(1 << 30).toRadixString(36)}', t, sigNid()),
      ];
      final p = <String, dynamic>{
        'firma': firma,
        'noche': noche,
        'turno_ref': ref,
        'guardia': s.userNombre ?? '',
        'ci': s.guardCi ?? '',
        'items': [...previas, ...nuevas].map((v) => v.toJson()).toList(),
        'subido': false,
      };
      await _guardarPlan(p);
      await _programar(nuevas);
      await _subirPlan(p, nuevas);
      await _revisarPermisos();
    } catch (_) {
    } finally {
      _planificando = false;
    }
  }

  static Future<void> _programar(List<Verificacion> items) async {
    await Notificaciones.init();
    final ahora = DateTime.now();
    for (final v in items) {
      if (v.hecha || !v.t.isAfter(ahora)) continue;
      try {
        await Notificaciones.plugin.zonedSchedule(
          v.nid,
          'CONTROL DE PRESENCIA NOCTURNA',
          'Verificación obligatoria de presencia. Complete su registro para detener la alarma.',
          tz.TZDateTime.from(v.t, tz.local),
          Notificaciones.detallesPresencia(),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          payload: 'presencia|${v.pid}',
        );
      } catch (_) {
        // Sin permiso de alarma exacta: se intenta con la menos exacta.
        try {
          await Notificaciones.plugin.zonedSchedule(
            v.nid,
            'CONTROL DE PRESENCIA NOCTURNA',
            'Verificación obligatoria de presencia. Complete su registro para detener la alarma.',
            tz.TZDateTime.from(v.t, tz.local),
            Notificaciones.detallesPresencia(),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
            payload: 'presencia|${v.pid}',
          );
          await _incidencia('sin_alarma_exacta', 'El celular no permite alarmas exactas: la verificación puede sonar con atraso.');
        } catch (_) {}
      }
    }
  }

  /// El plan va a la nube (supervisión ve las próximas verificaciones; el
  /// guardia no las ve en la app).
  static Future<void> _subirPlan(Map<String, dynamic> p, [List<Verificacion>? soloNuevas]) async {
    final items = soloNuevas ?? _items(p);
    await Cloud.evento('PresenciaPlan', detalle: {
      'noche': p['noche'],
      'turno_ref': p['turno_ref'],
      'desde': desde,
      'hasta': hasta,
      'max_min': maxMin,
      'puesto': AppState.instance.bloque,
      'items': [for (final v in items) {'pid': v.pid, 't': v.t.toUtc().toIso8601String()}],
    });
    p['subido'] = true;
    await _guardarPlan(p);
  }

  static final Set<String> _incidenciasDichas = {};
  static Future<void> _incidencia(String clave, String texto) async {
    if (_incidenciasDichas.contains(clave)) return;
    _incidenciasDichas.add(clave);
    await Cloud.evento('PresenciaIncidencia', detalle: {'clase': clave, 'motivo': texto});
  }

  /// Permisos que necesita la alarma; lo que falte se avisa a supervisión
  /// (INCIDENCIA TÉCNICA) y se pide al guardia.
  static Future<void> _revisarPermisos() async {
    try {
      if (!await Permission.notification.isGranted) {
        await Permission.notification.request();
        if (!await Permission.notification.isGranted) {
          await _incidencia('sin_notificaciones', 'Las notificaciones de OSIRIS están desactivadas: la alarma no puede sonar.');
        }
      }
    } catch (_) {}
    try {
      final ok = await _canal.invokeMethod<bool>('puedePantallaCompleta') ?? true;
      if (!ok) {
        await _incidencia('sin_pantalla_completa', 'Falta el permiso de pantalla completa: la verificación no se abre sola con el celular bloqueado.');
        await _canal.invokeMethod('pedirPantallaCompleta');
      }
    } catch (_) {}
    try {
      if (!await Permission.ignoreBatteryOptimizations.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } catch (_) {}
  }

  /// Verificación que ya sonó y no se respondió (la más antigua).
  static Future<Verificacion?> pendiente() async {
    final plan = await _leerPlan();
    final ahora = DateTime.now();
    final items = _items(plan)..sort((a, b) => a.t.compareTo(b.t));
    for (final v in items) {
      if (v.hecha || v.t.isAfter(ahora)) continue;
      // Más de 12 h sin responder: queda como SIN RESPUESTA y deja de sonar.
      if (ahora.difference(v.t) > const Duration(hours: 12)) continue;
      return v;
    }
    return null;
  }

  static bool _abierta = false;

  /// Si hay una verificación sonando, abre la pantalla (una sola vez).
  /// Se llama al abrir la app, al volver a ella, al tocar la notificación y en
  /// cada latido.
  static Future<void> revisar() async {
    if (_abierta) return;
    final v = await pendiente();
    if (v == null) return;
    final st = nav.currentState;
    if (st == null) return;
    _abierta = true;
    try {
      await st.push(MaterialPageRoute(builder: (_) => PresenciaScreen(v: v), fullscreenDialog: true));
    } finally {
      _abierta = false;
    }
    // Si quedó otra sonando (dos alarmas seguidas), se abre la siguiente.
    final otra = await pendiente();
    if (otra != null && otra.pid != v.pid) revisar();
  }

  /// La alarma sigue sonando mientras la pantalla está abierta: se vuelve a
  /// mostrar la notificación (si el guardia bajó la cortina, el sonido vuelve).
  static Future<void> reactivarSonido(Verificacion v) async {
    try {
      await Notificaciones.plugin.show(
        v.nid,
        'CONTROL DE PRESENCIA NOCTURNA',
        'Verificación obligatoria de presencia. Complete su registro para detener la alarma.',
        Notificaciones.detallesPresencia(),
        payload: 'presencia|${v.pid}',
      );
    } catch (_) {}
  }

  static Future<void> sobreBloqueo(bool si) async {
    try { await _canal.invokeMethod('sobreBloqueo', {'si': si}); } catch (_) {}
  }

  /// Fotos ya usadas (huella SHA-256): ninguna sirve para otra verificación.
  static Future<bool> fotoUsada(String huella) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('presencia_huellas') ?? const []).contains(huella);
  }

  /// Registra la respuesta: evento con foto + firma, detiene la alarma.
  static Future<String> completar(Verificacion v, {
    required String firma,
    required String foto,
    required String huella,
    required DateTime abierta,
    Map<String, double>? gps,
  }) async {
    final ahora = DateTime.now();
    final demora = ahora.difference(v.t);
    final tarde = demora > Duration(minutes: maxMin);
    final estado = tarde ? 'tardia' : 'respondida';
    final plan = await _leerPlan();
    final s = AppState.instance;
    await Cloud.eventoConFotos('Presencia',
        detalle: {
          'pid': v.pid,
          'noche': plan?['noche'] ?? '',
          'turno_ref': plan?['turno_ref'] ?? '',
          'puesto': s.bloque,
          'programada': v.t.toUtc().toIso8601String(),
          'abierta': abierta.toUtc().toIso8601String(),
          'respondida': ahora.toUtc().toIso8601String(),
          'ts': ahora.toUtc().toIso8601String(),
          'demora_s': demora.inSeconds,
          'max_min': maxMin,
          'estado': estado,
          'firma': firma,
          'foto_sha256': huella,
          'device_id': Cloud.deviceId,
          if (gps != null) 'ubicacion': '${gps['lat']},${gps['lng']}',
        },
        fotos: [foto],
        sufijo: '_presencia',
        calidades: const ['registro']);
    // Se detiene la alarma y se marca como hecha.
    try { await Notificaciones.plugin.cancel(v.nid); } catch (_) {}
    if (plan != null) {
      final items = _items(plan);
      for (final x in items) {
        if (x.pid == v.pid) x.hecha = true;
      }
      plan['items'] = items.map((x) => x.toJson()).toList();
      await _guardarPlan(plan);
    }
    final prefs = await SharedPreferences.getInstance();
    final hs = prefs.getStringList('presencia_huellas') ?? <String>[];
    hs.add(huella);
    await prefs.setStringList('presencia_huellas', hs.length > 200 ? hs.sublist(hs.length - 200) : hs);
    return estado;
  }

  /// El guardia intentó salir de la verificación sin completarla.
  static Future<void> intentoSalir(Verificacion v) =>
      _incidencia('salir_${v.pid}', 'El guardia intentó salir de la verificación sin completarla.');
}
