import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'app_state.dart';

/// Recordatorios: ronda cada 2 horas y alarma de cierre de candados a las 00:00.
/// Ambos se activan/desactivan desde Configuracion.
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
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      'candados_channel',
      'Cierre de candados',
      description: 'Alarma a las 00:00 para cerrar los candados',
      importance: Importance.max,
    ));
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      'avisos_channel',
      'Avisos',
      description: 'Avisos inmediatos (uniforme, etc.)',
      importance: Importance.high,
    ));
    await androidImpl?.requestNotificationsPermission();
    _init = true;
  }

  /// (Re)programa los recordatorios segun la configuracion actual.
  static Future<void> programarRecordatorios() async {
    await init();
    await _plugin.cancelAll();
    final s = AppState.instance;

    if (s.notifRondas) {
      const detalles = NotificationDetails(
        android: AndroidNotificationDetails(
          'rondas_channel', 'Recordatorio de rondas',
          channelDescription: 'Avisa a los guardias cada 2 horas para hacer la ronda',
          importance: Importance.high, priority: Priority.high, icon: '@mipmap/ic_launcher',
        ),
      );
      for (int h = 0; h < 24; h += 2) {
        try {
          await _plugin.zonedSchedule(
            2000 + h,
            'Ronda pendiente',
            'Es hora de realizar la ronda de seguridad.',
            _proximaHora(h, 0),
            detalles,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: DateTimeComponents.time,
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
        await _plugin.zonedSchedule(
          3000,
          '🔒 Cerrar los candados',
          'Son las 00:00. Recuerda cerrar todos los candados del edificio.',
          _proximaHora(0, 0),
          detalles,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.time,
        );
      } catch (_) {}
    }
  }

  /// Compatibilidad: usado al arrancar la app.
  static Future<void> programarRondas() => programarRecordatorios();

  /// Muestra un aviso inmediato (por ejemplo: guardia sin uniforme).
  static Future<void> mostrarAviso(String titulo, String cuerpo) async {
    await init();
    const detalles = NotificationDetails(
      android: AndroidNotificationDetails(
        'avisos_channel', 'Avisos',
        channelDescription: 'Avisos inmediatos',
        importance: Importance.high, priority: Priority.high, icon: '@mipmap/ic_launcher',
      ),
    );
    try {
      await _plugin.show(DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000, titulo, cuerpo, detalles);
    } catch (_) {}
  }

  static tz.TZDateTime _proximaHora(int hora, int minuto) {
    final ahora = tz.TZDateTime.now(tz.local);
    var d = tz.TZDateTime(tz.local, ahora.year, ahora.month, ahora.day, hora, minuto);
    if (!d.isAfter(ahora)) d = d.add(const Duration(days: 1));
    return d;
  }
}
