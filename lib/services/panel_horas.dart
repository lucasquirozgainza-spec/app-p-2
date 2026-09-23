import 'turnos.dart';

/// Un turno (ingreso → salida) de un guardia en un puesto (celular).
class RegistroTurno {
  final String guardia;
  final String puesto;          // id del celular (o "local")
  final DateTime inicio;
  final DateTime? fin;          // null = sigue en turno
  final int? nivelDeclarado;    // 12/24/36 marcado por el guardia
  final List<String> relevos;   // horarios de relevo del celular (ej. 09:00, 21:00)
  String? relevadoPor;          // quién lo relevó (lo calcula PanelHoras)

  RegistroTurno({
    required this.guardia,
    required this.puesto,
    required this.inicio,
    this.fin,
    this.nivelDeclarado,
    this.relevos = const [],
  });

  bool get cerrado => fin != null;
  double get horas => fin == null ? 0 : fin!.difference(inicio).inMinutes / 60.0;
  int get nivel => Turnos.nivelValido(nivelDeclarado) ?? (fin == null ? 12 : Turnos.nivelPorHoras(horas));
  double get extra =>
      fin == null ? 0 : Turnos.horasExtra(inicio: inicio, fin: fin!, nivel: nivel, horarios: relevos);
  double get atraso => Turnos.horasAtraso(inicio, relevos);
}

/// Resumen del mes de un guardia en un puesto.
class ResumenGuardia {
  final String guardia;
  final List<RegistroTurno> turnos = [];
  ResumenGuardia(this.guardia);

  Iterable<RegistroTurno> get _cerrados => turnos.where((t) => t.cerrado);
  int get dias => {for (final t in turnos) '${t.inicio.year}-${t.inicio.month}-${t.inicio.day}'}.length;
  int get n12 => _cerrados.where((t) => t.nivel == 12).length;
  int get n24 => _cerrados.where((t) => t.nivel == 24).length;
  int get n36 => _cerrados.where((t) => t.nivel == 36).length;
  int get dobles => _cerrados.fold(0, (a, t) => a + Turnos.dobles(t.nivel));
  double get horas => _cerrados.fold(0.0, (a, t) => a + t.horas);
  double get extra => _cerrados.fold(0.0, (a, t) => a + t.extra);
  int get vecesTarde => turnos.where((t) => t.atraso > 0).length;
}

/// Cuenta de horas entre DOS guardias que se relevan.
class BalancePar {
  final String a, b;
  double aEsperoPorB = 0; // horas que A se quedó porque B llegó tarde
  double bEsperoPorA = 0; // horas que B se quedó porque A llegó tarde
  BalancePar(this.a, this.b);

  double get neto => aEsperoPorB - bEsperoPorA;
  bool get aMano => neto.abs() < 0.25;

  /// Beneficiario: el que hizo esperar más al otro (trabajó menos).
  String? get beneficiario => aMano ? null : (neto > 0 ? b : a);
  /// Quien tiene horas a favor (esperó de más).
  String? get acreedor => aMano ? null : (neto > 0 ? a : b);
  double get horas => neto.abs();
}

/// Todo lo de un puesto (celular) en el mes.
class PanelPuesto {
  final String puesto;   // id
  String nombre;         // "Bloque A" o "Puesto 1"
  final Map<String, ResumenGuardia> guardias = {};
  final List<BalancePar> balances = [];
  final List<RegistroTurno> turnos = [];
  PanelPuesto(this.puesto, this.nombre);
}

class PanelHoras {
  /// Máxima diferencia entre la salida de uno y el ingreso del otro para
  /// considerar que fue un relevo.
  static const Duration ventanaRelevo = Duration(hours: 4);

  /// Arma el panel por puesto: resumen por guardia, quién relevó a quién y la
  /// cuenta entre cada par de guardias.
  /// [desde]/[hasta]: solo cuentan los turnos que EMPIEZAN en ese rango; los
  /// de afuera se usan únicamente para saber quién relevó a quién.
  static List<PanelPuesto> calcular(List<RegistroTurno> todos,
      {Map<String, String> nombres = const {}, DateTime? desde, DateTime? hasta}) {
    bool cuenta(RegistroTurno t) =>
        (desde == null || !t.inicio.isBefore(desde)) && (hasta == null || t.inicio.isBefore(hasta));
    final porPuesto = <String, PanelPuesto>{};
    for (final t in todos) {
      porPuesto.putIfAbsent(t.puesto, () => PanelPuesto(t.puesto, nombres[t.puesto] ?? '')).turnos.add(t);
    }
    int n = 0;
    final out = <PanelPuesto>[];
    for (final p in porPuesto.values) {
      n++;
      if (p.nombre.isEmpty) p.nombre = 'Puesto $n';
      p.turnos.sort((a, b) => a.inicio.compareTo(b.inicio));
      for (final t in p.turnos) {
        if (cuenta(t)) p.guardias.putIfAbsent(t.guardia, () => ResumenGuardia(t.guardia)).turnos.add(t);
      }
      // ¿Quién relevó a cada uno? El ingreso de OTRO guardia más cercano a su salida.
      final pares = <String, BalancePar>{};
      for (final t in p.turnos) {
        if (!t.cerrado) continue;
        RegistroTurno? mejor;
        int mejorDif = 1 << 30;
        for (final o in p.turnos) {
          if (identical(o, t) || o.guardia == t.guardia) continue;
          final dif = o.inicio.difference(t.fin!).inMinutes.abs();
          if (dif <= ventanaRelevo.inMinutes && dif < mejorDif) {
            mejor = o;
            mejorDif = dif;
          }
        }
        if (mejor == null) continue;
        t.relevadoPor = mejor.guardia;
        if (!cuenta(t)) continue; // fuera del mes: solo servía para emparejar
        final ab = [t.guardia, mejor.guardia]..sort();
        final par = pares.putIfAbsent('${ab[0]}|${ab[1]}', () => BalancePar(ab[0], ab[1]));
        // t esperó (extra) porque "mejor" llegó tarde.
        if (t.guardia == par.a) {
          par.aEsperoPorB += t.extra;
        } else {
          par.bEsperoPorA += t.extra;
        }
      }
      p.balances.addAll(pares.values);
      p.turnos.removeWhere((t) => !cuenta(t));
      if (p.turnos.isNotEmpty) out.add(p);
    }
    return out;
  }
}
