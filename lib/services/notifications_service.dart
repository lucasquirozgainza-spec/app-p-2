import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Recordatorio de rondas: notificación cada 2 horas (horas pares).
class Notificaciones {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _init = false;

  static Future<void> init() async {
    if (_init) return;
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('America/La_Paz'));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Etc/GMT+4'));
    }
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));

    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      'rondas_channel',
      'Recordatorio de rondas',
      description: 'Avisa a los guardias cada 2 horas para hacer la ronda',
      importance: Importance.high,
    ));
    await androidImpl?.requestNotificationsPermission();
    _init = true;
  }

  /// Programa un recordatorio cada 2 horas (00,02,...,22), repetido cada día.
  static Future<void> programarRondas() async {
    await init();
    await _plugin.cancelAll();
    const detalles = NotificationDetails(
      android: AndroidNotificationDetails(
        'rondas_channel',
        'Recordatorio de rondas',
        channelDescription: 'Avisa a los guardias cada 2 horas para hacer la ronda',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
    );
    for (int h = 0; h < 24; h += 2) {
      try {
        await _plugin.zonedSchedule(
          2000 + h,
          'Ronda pendiente',
          'Es hora de realizar la ronda de seguridad.',
          _proximaHora(h),
          detalles,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.time,
        );
      } catch (_) {
        // Si el equipo no permite programar, se ignora sin romper la app.
      }
    }
  }

  static tz.TZDateTime _proximaHora(int hora) {
    final ahora = tz.TZDateTime.now(tz.local);
    var d = tz.TZDateTime(tz.local, ahora.year, ahora.month, ahora.day, hora);
    if (!d.isAfter(ahora)) d = d.add(const Duration(days: 1));
    return d;
  }
}
