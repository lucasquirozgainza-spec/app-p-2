/// Reglas ÚNICAS de turnos y horas (las usan la pantalla Guardias, los
/// reportes PDF y el reporte de personal, así todos dan el mismo número).
///
/// - Turnos normales: diurno 08:00–20:00 y nocturno 20:00–08:00 (12 h). Cada
///   celular puede tener su propio horario de relevo (bloques/torres); si no
///   tiene, se usa el normal.
/// - Tipo de turno: lo DECLARA el guardia (12 h normal, 24 h doblado, 36 h
///   triple). Si un turno viejo no lo tiene, se estima por la duración.
/// - El turno "programado" empieza en la hora de relevo más cercana al ingreso
///   y dura 12/24/36 h (cruza medianoche y varios días sin problema: son
///   fechas completas, no solo horas).
/// - Las horas a favor / en contra se generan en cada RELEVO (ver
///   PanelHoras): si el que entra llega tarde, el que esperó gana esas horas
///   y el que llegó tarde las pierde; si el que sale se va antes, pierde lo
///   que no cubrió y el que entró antes lo gana.
/// - Tolerancia (editable por edificio, 15 min por defecto): hasta ese margen
///   la diferencia no cuenta (8:00 vs 8:12 no pasa nada). Pasado el margen se
///   cuentan TODOS los minutos (llegar 8:20 = 20 min en contra, no 5).
class Turnos {
  static const List<int> niveles = [12, 24, 36];
  static const int toleranciaPorDefecto = 15; // minutos

  /// Tolerancia del edificio en minutos (0 a 60), guardada en su
  /// configuración ('tolerancia_min'), que se sincroniza entre celulares.
  static int toleranciaDe(Map? modulos) {
    final v = modulos?['tolerancia_min'];
    final n = v is int ? v : int.tryParse('${v ?? ''}');
    if (n == null) return toleranciaPorDefecto;
    return n < 0 ? 0 : (n > 60 ? 60 : n);
  }

  /// Horario normal si el celular no tiene uno configurado.
  static const List<String> porDefecto = ['08:00', '20:00'];

  /// Id ÚNICO de un turno en la nube: celular + id local. Une el ingreso con
  /// su salida, sus cambios de 24/36 h y sus correcciones.
  static String ref(String deviceId, Object? idLocal) => '${deviceId}_t$idLocal';

  /// Saldo firmado: "+3 h 30 min", "-1 h", "0 h".
  static String saldo(double horas) {
    final m = (horas * 60).round();
    if (m == 0) return '0 h';
    return '${m > 0 ? '+' : '-'}${duracion(Duration(minutes: m.abs()))}';
  }

  /// "HH:mm" → [hora, minuto] o null si no es válido.
  static List<int>? parseHora(String? s) {
    if (s == null) return null;
    final m = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*$').firstMatch(s);
    if (m == null) return null;
    final h = int.parse(m.group(1)!), mi = int.parse(m.group(2)!);
    if (h > 23 || mi > 59) return null;
    return [h, mi];
  }

  static String fmtHora(int h, int m) => '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

  /// Horarios válidos (sin vacíos ni repetidos).
  static List<String> limpiar(List<String?> horarios) {
    final out = <String>[];
    for (final h in horarios) {
      final p = parseHora(h);
      if (p == null) continue;
      final f = fmtHora(p[0], p[1]);
      if (!out.contains(f)) out.add(f);
    }
    return out;
  }

  /// Relevo programado más cercano a [t] (dentro de ±6 h) o null.
  static DateTime? relevoCercano(DateTime t, List<String> horarios) {
    DateTime? mejor;
    for (final h in limpiar(horarios)) {
      final p = parseHora(h)!;
      for (int d = -1; d <= 1; d++) {
        final c = DateTime(t.year, t.month, t.day, p[0], p[1]).add(Duration(days: d));
        final diff = t.difference(c).inMinutes.abs();
        if (diff <= 6 * 60 && (mejor == null || diff < t.difference(mejor).inMinutes.abs())) {
          mejor = c;
        }
      }
    }
    return mejor;
  }

  /// Minutos de atraso respecto al relevo más cercano (negativo = llegó antes).
  static int? minutosTarde(DateTime llegada, List<String> horarios) {
    final r = relevoCercano(llegada, horarios);
    return r == null ? null : llegada.difference(r).inMinutes;
  }

  /// Tipo de turno más cercano a las horas trabajadas (turnos sin declarar).
  static int nivelPorHoras(double horas) {
    int best = niveles.first;
    for (final n in niveles) {
      if ((horas - n).abs() < (horas - best).abs()) best = n;
    }
    return best;
  }

  /// Nivel válido (12/24/36) o null.
  static int? nivelValido(Object? v) {
    final n = v is int ? v : int.tryParse('${v ?? ''}');
    return (n != null && niveles.contains(n)) ? n : null;
  }

  /// Inicio PROGRAMADO del turno: la hora de relevo más cercana al ingreso
  /// (sin horario configurado, el ingreso real).
  static DateTime inicioProgramado(DateTime inicio, List<String> horarios) =>
      relevoCercano(inicio, horarios) ?? inicio;

  /// Fin PROGRAMADO: inicio programado + 12/24/36 h.
  static DateTime finProgramado(DateTime inicio, int nivel, List<String> horarios) =>
      inicioProgramado(inicio, horarios).add(Duration(hours: nivel));

  /// Veces que dobló: 24 h = 1, 36 h = 2.
  static int dobles(int nivel) => nivel >= 36 ? 2 : (nivel >= 24 ? 1 : 0);

  /// Fin previsto de un turno declarado.
  static DateTime finPrevisto(DateTime inicio, int nivel, List<String> horarios) =>
      finProgramado(inicio, nivel, horarios);

  /// "11 h 40 min" / "45 min".
  static String duracion(Duration d) {
    final m = d.inMinutes.abs();
    final h = m ~/ 60, r = m % 60;
    if (h == 0) return '$r min';
    return r == 0 ? '$h h' : '$h h ${r.toString().padLeft(2, '0')} min';
  }

  /// Duración entre dos relevos del día (ej. 08:30 → 20:30 = 12 h).
  static Duration entre(String a, String b) {
    final pa = parseHora(a)!, pb = parseHora(b)!;
    var m = (pb[0] * 60 + pb[1]) - (pa[0] * 60 + pa[1]);
    if (m <= 0) m += 24 * 60;
    return Duration(minutes: m);
  }
}
