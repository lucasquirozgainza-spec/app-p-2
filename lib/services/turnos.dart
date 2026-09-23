/// Reglas ÚNICAS de turnos y horas extra (las usan la pantalla Guardias, los
/// reportes PDF y el reporte de personal, así todos dan el mismo número).
///
/// - Tipo de turno: lo DECLARA el guardia (12 h normal, 24 h doblado, 36 h
///   triple). Si un turno viejo no lo tiene, se estima por la duración.
/// - El turno "programado" empieza en la hora de relevo más cercana al ingreso
///   (aunque el guardia llegue antes o tarde) y dura 12/24/36 h.
/// - Hora EXTRA = lo que el guardia se quedó DESPUÉS del fin programado,
///   esperando a que llegue su relevo. Llegar temprano no suma.
/// - ATRASO = lo que llegó tarde respecto a su hora de relevo.
/// - Diferencias de hasta 30 min no cuentan (8:00 vs 8:08 no pasa nada).
/// Ej. relevos 09:00/21:00: el nocturno llega 22:00 → el diurno sale 22:00 →
/// diurno 1 h extra (se la debe el nocturno). Si al otro día el diurno llega
/// 10:00, el nocturno espera 1 h → quedan a mano (ver PanelHoras).
class Turnos {
  static const List<int> niveles = [12, 24, 36];
  static const double tolerancia = 0.5; // horas

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

  /// Horas EXTRA: tiempo que se quedó pasado su fin programado (esperando al
  /// relevo). Sin horario configurado equivale a horas trabajadas − turno.
  static double horasExtra({
    required DateTime inicio,
    required DateTime fin,
    required int nivel,
    List<String> horarios = const [],
  }) {
    final e = fin.difference(finProgramado(inicio, nivel, horarios)).inMinutes / 60.0;
    return e > tolerancia ? e : 0.0;
  }

  /// Horas de ATRASO al entrar (0 si llegó a tiempo o antes, o sin horario).
  static double horasAtraso(DateTime inicio, List<String> horarios) {
    final a = inicio.difference(inicioProgramado(inicio, horarios)).inMinutes / 60.0;
    return a > tolerancia ? a : 0.0;
  }

  /// Horas que faltaron: salió antes de su fin programado.
  static double horasFalta({
    required DateTime inicio,
    required DateTime fin,
    required int nivel,
    List<String> horarios = const [],
  }) {
    final f = finProgramado(inicio, nivel, horarios).difference(fin).inMinutes / 60.0;
    return f > tolerancia ? f : 0.0;
  }

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
