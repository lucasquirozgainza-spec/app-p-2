import 'dart:typed_data';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'app_state.dart';

/// Recordatorios y alarmas del celular:
/// - Recordatorio de ronda: cada X horas (lo define supervisión por edificio)
///   contadas desde la ÚLTIMA ronda (o desde el ingreso al turno), solo dentro
///   del horario configurado y solo con un turno abierto.
/// - Alarma de candados a las 00:00.
/// - Alarma de CONTROL DE PRESENCIA NOCTURNA (ver presencia_service.dart).
///
/// Ids de notificación: 2000-2099 rondas · 3000 candados · 6000-6099 presencia.
class Notificaciones {
  static final plugin = FlutterLocalNotificationsPlugin();
  static bool _init = false;

  /// Al tocar una notificación (o abrirse la app por la alarma de presencia).
  static void Function(String? payload)? alTocar;

  static const canalPresencia = 'presencia_alarma_v1';

  static Future<void> init() async {
    if (_init) return;
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('America/La_Paz'));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Etc/GMT+4'));
    }
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (r) {
        final f = alTocar;
        if (f != null) f(r.payload);
      },
    );

    final androidImpl = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      'rondas_channel',
      'Recordatorio de rondas',
      description: 'Avisa al guardia cuando toca hacer la ronda',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ));
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      'candados_channel',
      'Cierre de candados',
      description: 'Alarma a las 00:00 para cerrar los candados',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ));
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      'avisos_channel',
      'Avisos',
      description: 'Avisos inmediatos (uniforme, etc.)',
      importance: Importance.high,
    ));
    // Alarma de presencia: sonido de ALARMA del sistema (suena aunque el
    // celular esté en silencio, como el despertador).
    await androidImpl?.createNotificationChannel(AndroidNotificationChannel(
      canalPresencia,
      'Control de presencia nocturna',
      description: 'Alarma obligatoria de verificación de presencia',
      importance: Importance.max,
      playSound: true,
      sound: const UriAndroidNotificationSound('content://settings/system/alarm_alert'),
      audioAttributesUsage: AudioAttributesUsage.alarm,
      enableVibration: true,
      vibrationPattern: Int64List.fromList(const [0, 1200, 600, 1200, 600, 1200]),
    ));
    await androidImpl?.requestNotificationsPermission();
    // Permiso de ALARMA EXACTA (Android 12+): sin esto las alarmas no suenan a tiempo.
    try { await androidImpl?.requestExactAlarmsPermission(); } catch (_) {}
    _init = true;
  }

  /// Hora de la última ronda de este celular (o del ingreso al turno).
  static Future<void> marcarRonda([DateTime? cuando]) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ultima_ronda', (cuando ?? DateTime.now()).toIso8601String());
  }

  static int _min(String hhmm) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm.trim());
    if (m == null) return -1;
    return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
  }

  /// ¿La hora [t] cae dentro del horario desde-hasta? (desde == hasta: todo el día;
  /// desde > hasta: cruza la medianoche, ej. 20:00 a 06:00).
  static bool dentroHorario(DateTime t, String desde, String hasta) {
    final d = _min(desde), h = _min(hasta);
    if (d < 0 || h < 0 || d == h) return true;
    final x = t.hour * 60 + t.minute;
    return d < h ? (x >= d && x < h) : (x >= d || x < h);
  }

  /// (Re)programa los recordatorios según la configuración actual.
  static Future<void> programarRecordatorios() async {
    await init();
    // Solo los de ronda y candados: la alarma de presencia NO se toca aquí.
    for (int i = 2000; i < 2100; i++) {
      try { await plugin.cancel(i); } catch (_) {}
    }
    try { await plugin.cancel(3000); } catch (_) {}
    final s = AppState.instance;
    final m = s.modulos;

    // Recordatorio de ronda: lo puede apagar supervisión (ronda_rec = false)
    // o el propio celular; solo con turno abierto.
    final recEdificio = m['ronda_rec'] != false;
    if (s.notifRondas && recEdificio && s.turnoActivoId != null && !s.soloLocal) {
      final detalles = NotificationDetails(
        android: AndroidNotificationDetails(
          'rondas_channel', 'Recordatorio de rondas',
          channelDescription: 'Avisa al guardia cuando toca hacer la ronda',
          importance: Importance.max, priority: Priority.max, icon: '@mipmap/ic_launcher',
          category: AndroidNotificationCategory.reminder,
          visibility: NotificationVisibility.public,
          vibrationPattern: Int64List.fromList(const [0, 800, 400, 800]),
        ),
      );
      final cada = s.rondaCada.clamp(1, 12);
      final desde = '${m['ronda_rec_desde'] ?? ''}', hasta = '${m['ronda_rec_hasta'] ?? ''}';
      final prefs = await SharedPreferences.getInstance();
      final ahora = DateTime.now();
      var base = DateTime.tryParse(prefs.getString('ultima_ronda') ?? '') ?? ahora;
      if (base.isAfter(ahora)) base = ahora;
      // Recordatorios de las próximas 24 h: última ronda + cada, + 2 cada...
      // Si ya se pasó la hora, el primero sale en 1 minuto.
      int id = 2000;
      for (int k = 1; id < 2040; k++) {
        var t = base.add(Duration(hours: cada * k));
        if (t.isAfter(ahora.add(const Duration(hours: 24)))) break;
        if (!t.isAfter(ahora)) {
          // vencida: solo la más reciente se avisa ya (no una por cada hora perdida)
          final sig = base.add(Duration(hours: cada * (k + 1)));
          if (!sig.isAfter(ahora)) continue;
          t = ahora.add(const Duration(minutes: 1));
        }
        if (!dentroHorario(t, desde, hasta)) continue;
        try {
          await plugin.zonedSchedule(
            id++,
            'Ronda pendiente',
            'Es hora de hacer la ronda de seguridad (cada $cada h).',
            tz.TZDateTime.from(t, tz.local),
            detalles,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
            payload: 'ronda',
          );
        } catch (_) {}
      }
    }

    if (s.alarmaCandados) {
      const detalles = NotificationDetails(
        android: AndroidNotificationDetails(
          'candados_channel', 'Cierre de candados',
          channelDescription: 'Alarma a las 00:00 para cerrar los candados',
          importance: Importance.max, priority: Priority.max, icon: '@mipmap/ic_launcher',
        ),
      );
      try {
        await plugin.zonedSchedule(
          3000,
          '🔒 Cerrar los candados',
          'Son las 00:00. Recuerda cerrar todos los candados del edificio.',
          _proximaHora(0, 0),
          detalles,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.time,
        );
      } catch (_) {}
    }
  }

  /// Compatibilidad: usado al arrancar la app.
  static Future<void> programarRondas() => programarRecordatorios();

  /// Muestra un aviso inmediato (por ejemplo: guardia sin uniforme).
  static Future<void> mostrarAviso(String titulo, String cuerpo, {int? id}) async {
    await init();
    const detalles = NotificationDetails(
      android: AndroidNotificationDetails(
        'avisos_channel', 'Avisos',
        channelDescription: 'Avisos inmediatos',
        importance: Importance.high, priority: Priority.high, icon: '@mipmap/ic_launcher',
      ),
    );
    try {
      await plugin.show(id ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000, titulo, cuerpo, detalles);
    } catch (_) {}
  }

  /// Detalles de la alarma de presencia: pantalla completa, sonido de alarma
  /// que se REPITE (insistente) y no se puede deslizar para quitarla.
  static NotificationDetails detallesPresencia() => NotificationDetails(
        android: AndroidNotificationDetails(
          canalPresencia, 'Control de presencia nocturna',
          channelDescription: 'Alarma obligatoria de verificación de presencia',
          importance: Importance.max,
          priority: Priority.max,
          icon: '@mipmap/ic_launcher',
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
          audioAttributesUsage: AudioAttributesUsage.alarm,
          sound: const UriAndroidNotificationSound('content://settings/system/alarm_alert'),
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList(const [0, 1200, 600, 1200, 600, 1200]),
          ongoing: true,
          autoCancel: false,
          visibility: NotificationVisibility.public,
          ticker: 'Control de presencia nocturna',
          // FLAG_INSISTENT (4): el sonido se repite hasta que se completa la verificación.
          additionalFlags: Int32List.fromList(const [4]),
        ),
      );

  static tz.TZDateTime _proximaHora(int hora, int minuto) {
    final ahora = tz.TZDateTime.now(tz.local);
    var d = tz.TZDateTime(tz.local, ahora.year, ahora.month, ahora.day, hora, minuto);
    if (!d.isAfter(ahora)) d = d.add(const Duration(days: 1));
    return d;
  }

  /// Texto del horario de recordatorio de ronda (para Configuración).
  static String horarioRonda() {
    final m = AppState.instance.modulos;
    final d = '${m['ronda_rec_desde'] ?? ''}', h = '${m['ronda_rec_hasta'] ?? ''}';
    if (_min(d) < 0 || _min(h) < 0 || d == h) return 'todo el día';
    return 'de $d a $h';
  }
}
