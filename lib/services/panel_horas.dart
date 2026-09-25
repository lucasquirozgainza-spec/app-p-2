import 'turnos.dart';

/// Una hora A FAVOR (+) o EN CONTRA (−) de un guardia, con su origen exacto.
/// Cada movimiento sale de UN relevo (o de un ingreso/salida sin relevo) y
/// lleva la hora programada y la hora real que lo generaron: así se puede
/// auditar de dónde salió cada minuto.
class Movimiento {
  final DateTime programado; // hora de relevo programada (ej. 20:00)
  final DateTime real;       // hora real registrada (ingreso o salida)
  final double horas;        // + a favor / − en contra
  final String motivo;
  final String? con;         // el otro guardia del relevo (si hubo)
  const Movimiento({
    required this.programado,
    required this.real,
    required this.horas,
    required this.motivo,
    this.con,
  });
}

/// Un turno (ingreso → salida) de un guardia en un puesto (celular).
class RegistroTurno {
  /// Id único y estable del turno (turno_ref de la nube, o "local<id>").
  /// Dos copias del mismo turno (reintentos, dos lecturas) tienen el mismo id
  /// y se cuentan UNA sola vez.
  final String id;
  final String edificio;
  final String guardia;
  final String puesto;          // id del celular (o "local")
  DateTime inicio;
  DateTime? fin;                // null = sigue en turno
  int? nivelDeclarado;          // 12/24/36 marcado por el guardia
  final List<String> relevos;   // horarios de relevo del celular (ej. 09:00, 21:00)
  String? refIngreso;           // registro que dio el ingreso (auditoría)
  String? refSalida;            // registro que dio la salida (auditoría)
  final List<String> notas = []; // correcciones, duplicados ignorados, etc.
  bool corregido = false;
  /// Estado forzado: 'sin salida', 'sin ingreso', 'anulado', 'inconsistente'.
  String? marca;

  // ---- Calculado por PanelHoras.calcular ----
  List<String> horariosUsados = const [];
  DateTime? progInicio, progFin;
  String? relevadoPor;          // quién lo relevó
  String? releveA;              // a quién relevó
  final List<Movimiento> movimientos = [];

  RegistroTurno({
    required this.id,
    required this.guardia,
    required this.puesto,
    required this.inicio,
    this.edificio = '',
    this.fin,
    this.nivelDeclarado,
    this.relevos = const [],
    this.refIngreso,
    this.refSalida,
  });

  /// 'ok' (cerrado), 'abierto' (en turno) o la marca de un registro que no
  /// entra en el cálculo.
  String get estado => marca ?? (fin == null ? 'abierto' : 'ok');
  bool get valido => estado == 'ok' || estado == 'abierto';
  bool get cerrado => estado == 'ok';
  double get horas => (!cerrado) ? 0 : fin!.difference(inicio).inMinutes / 60.0;
  int get nivel => Turnos.nivelValido(nivelDeclarado) ?? (cerrado ? Turnos.nivelPorHoras(horas) : 12);
  double get aFavor => movimientos.fold(0.0, (a, m) => m.horas > 0 ? a + m.horas : a);
  double get enContra => movimientos.fold(0.0, (a, m) => m.horas < 0 ? a - m.horas : a);
  double get saldo => aFavor - enContra;
  bool get llegoTarde => movimientos.any((m) => m.horas < 0 && m.motivo.startsWith('Llegó tarde'));

  // Compatibilidad con reportes anteriores.
  double get extra => aFavor;
  double get atraso => movimientos
      .where((m) => m.horas < 0 && m.motivo.startsWith('Llegó tarde'))
      .fold(0.0, (a, m) => a - m.horas);

  void _reiniciar() {
    horariosUsados = const [];
    progInicio = null;
    progFin = null;
    relevadoPor = null;
    releveA = null;
    movimientos.clear();
  }
}

/// Resumen de un guardia en el periodo.
class ResumenGuardia {
  final String guardia;
  final List<RegistroTurno> turnos = [];
  ResumenGuardia(this.guardia);

  Iterable<RegistroTurno> get _validos => turnos.where((t) => t.valido);
  Iterable<RegistroTurno> get _cerrados => turnos.where((t) => t.cerrado);
  int get dias => {for (final t in _validos) '${t.inicio.year}-${t.inicio.month}-${t.inicio.day}'}.length;
  int get n12 => _cerrados.where((t) => t.nivel == 12).length;
  int get n24 => _cerrados.where((t) => t.nivel == 24).length;
  int get n36 => _cerrados.where((t) => t.nivel == 36).length;
  int get dobles => _cerrados.fold(0, (a, t) => a + Turnos.dobles(t.nivel));
  double get horas => _cerrados.fold(0.0, (a, t) => a + t.horas);
  double get aFavor => _validos.fold(0.0, (a, t) => a + t.aFavor);
  double get enContra => _validos.fold(0.0, (a, t) => a + t.enContra);
  double get saldo => aFavor - enContra;
  int get vecesTarde => _validos.where((t) => t.llegoTarde).length;
  int get incompletos => turnos.where((t) => !t.valido).length;
  double get extra => aFavor; // compatibilidad
}

/// Cuenta de horas entre DOS guardias que se relevan.
class BalancePar {
  final String a, b;
  double aEsperoPorB = 0; // horas que A cubrió por B (B llegó tarde o salió antes)
  double bEsperoPorA = 0; // horas que B cubrió por A
  BalancePar(this.a, this.b);

  double get neto => aEsperoPorB - bEsperoPorA;
  // A mano solo si la diferencia es 0 minutos (se cuentan minutos completos).
  bool get aMano => (neto * 60).round() == 0;

  /// Beneficiario: el que hizo cubrir más al otro (trabajó menos).
  String? get beneficiario => aMano ? null : (neto > 0 ? b : a);
  /// Quien tiene horas a favor (cubrió de más).
  String? get acreedor => aMano ? null : (neto > 0 ? a : b);
  double get horas => neto.abs();
}

/// Todo lo de un puesto (celular) en el periodo.
class PanelPuesto {
  final String puesto;   // id
  int toleranciaMin = Turnos.toleranciaPorDefecto; // con la que se calculó
  String nombre;         // "Bloque A" o "Puesto 1"
  final Map<String, ResumenGuardia> guardias = {};
  final List<BalancePar> balances = [];
  final List<RegistroTurno> turnos = [];
  PanelPuesto(this.puesto, this.nombre);
}

/// Cálculo ÚNICO de horas a favor / en contra (pantalla, PDF y reportes usan
/// esto; no hay otro cálculo que pueda dar un número distinto).
///
/// Regla por relevo (A sale, B entra, P = hora de relevo programada):
/// - B llega después de P: B −(llegada − P). A +(lo que realmente esperó,
///   hasta que llegó B o hasta que se fue).
/// - A se va antes de P: A −(P − salida). B +(lo que cubrió antes de P).
/// - Sin relevo registrado: salir después del fin programado = a favor;
///   salir antes = en contra; llegar tarde = en contra. Llegar temprano por
///   voluntad propia (sin reemplazar a nadie) no suma.
/// - Tolerancia (editable por edificio, 15 min por defecto): hasta ese margen
///   no cuenta; pasado el margen se cuentan los minutos COMPLETOS (con 15 min,
///   20 min tarde = 20 min, no 5).
/// Es determinista: el mismo conjunto de registros da siempre el mismo
/// resultado, sin importar el orden en que llegaron ni cuántas veces se leyó.
class PanelHoras {
  /// Arma el panel por puesto. [desde]/[hasta]: solo cuentan los turnos que
  /// EMPIEZAN en ese rango; los de afuera sirven solo para saber quién relevó
  /// a quién en los bordes del periodo.
  static List<PanelPuesto> calcular(List<RegistroTurno> todos,
      {Map<String, String> nombres = const {},
      DateTime? desde,
      DateTime? hasta,
      int toleranciaMin = Turnos.toleranciaPorDefecto}) {
    final tol = toleranciaMin / 60.0;
    bool enPeriodo(RegistroTurno t) =>
        (desde == null || !t.inicio.isBefore(desde)) && (hasta == null || t.inicio.isBefore(hasta));

    // Un turno repetido (mismo id) se cuenta una sola vez.
    final vistos = <String>{};
    final porPuesto = <String, List<RegistroTurno>>{};
    for (final t in todos) {
      if (!vistos.add(t.id)) continue;
      t._reiniciar();
      porPuesto.putIfAbsent(t.puesto, () => []).add(t);
    }

    final out = <PanelPuesto>[];
    int n = 0;
    for (final puesto in (porPuesto.keys.toList()..sort())) {
      n++;
      final lista = porPuesto[puesto]!..sort(_orden);
      _calcularPuesto(lista, tol);

      final p = PanelPuesto(puesto, nombres[puesto] ?? '')..toleranciaMin = toleranciaMin;
      if (p.nombre.isEmpty) p.nombre = puesto == 'local' ? 'Este celular' : 'Puesto $n';
      final pares = <String, BalancePar>{};
      for (final t in lista) {
        if (!enPeriodo(t)) continue;
        p.turnos.add(t);
        p.guardias.putIfAbsent(t.guardia, () => ResumenGuardia(t.guardia)).turnos.add(t);
        // Cuenta entre pares: lo que cada uno cubrió por el otro.
        for (final m in t.movimientos) {
          if (m.con == null || m.horas <= 0) continue;
          final ab = [t.guardia, m.con!]..sort();
          final par = pares.putIfAbsent('${ab[0]}|${ab[1]}', () => BalancePar(ab[0], ab[1]));
          if (t.guardia == par.a) {
            par.aEsperoPorB += m.horas;
          } else {
            par.bEsperoPorA += m.horas;
          }
        }
      }
      p.balances.addAll(pares.values.toList()..sort((x, y) => '${x.a}|${x.b}'.compareTo('${y.a}|${y.b}')));
      if (p.turnos.isNotEmpty) out.add(p);
    }
    return out;
  }

  static int _orden(RegistroTurno a, RegistroTurno b) {
    final c = a.inicio.compareTo(b.inicio);
    if (c != 0) return c;
    final g = a.guardia.compareTo(b.guardia);
    return g != 0 ? g : a.id.compareTo(b.id);
  }

  static double _h(DateTime a, DateTime b) => a.difference(b).inMinutes / 60.0;

  static void _calcularPuesto(List<RegistroTurno> lista, double tol) {
    // Horario de cada turno: el que traía su ingreso; si no (registros
    // viejos), el último conocido de ese puesto; si no, el normal 08/20.
    List<String>? ultimo;
    List<String>? primero;
    for (final t in lista) {
      if (t.relevos.isNotEmpty) {
        primero = t.relevos;
        break;
      }
    }
    for (final t in lista) {
      if (t.relevos.isNotEmpty) ultimo = t.relevos;
      t.horariosUsados = t.relevos.isNotEmpty ? t.relevos : (ultimo ?? primero ?? Turnos.porDefecto);
    }
    final validos = lista.where((t) => t.valido).toList();
    for (final t in validos) {
      t.progInicio = Turnos.inicioProgramado(t.inicio, t.horariosUsados);
      t.progFin = t.progInicio!.add(Duration(hours: t.nivel));
    }

    // Emparejar cada salida con el ingreso del relevo: otro guardia cuyo
    // turno programado empieza EXACTAMENTE donde termina el de A.
    final tomados = <RegistroTurno>{};
    for (final a in validos) {
      if (!a.cerrado) continue;
      RegistroTurno? mejor;
      int mejorDif = 1 << 30;
      for (final b in validos) {
        if (identical(a, b) || b.guardia == a.guardia || tomados.contains(b)) continue;
        if (b.progInicio != a.progFin) continue;
        final dif = b.inicio.difference(a.fin!).inMinutes.abs();
        if (dif < mejorDif || (dif == mejorDif && mejor != null && b.id.compareTo(mejor.id) < 0)) {
          mejor = b;
          mejorDif = dif;
        }
      }
      if (mejor != null) {
        tomados.add(mejor);
        a.relevadoPor = mejor.guardia;
        mejor.releveA = a.guardia;
        _relevo(a, mejor, a.progFin!, tol);
      } else {
        _finSinRelevo(a, tol);
      }
    }
    for (final b in validos) {
      if (!tomados.contains(b)) _inicioSinRelevo(b, tol);
    }
  }

  static void _relevo(RegistroTurno a, RegistroTurno b, DateTime p, double tol) {
    final entra = b.inicio, sale = a.fin!;
    if (entra.isAfter(p)) {
      final tarde = _h(entra, p);
      if (tarde > tol) {
        b.movimientos.add(Movimiento(
            programado: p, real: entra, horas: -tarde, motivo: 'Llegó tarde al relevo', con: a.guardia));
      }
      final espero = _h(sale.isBefore(entra) ? sale : entra, p);
      if (espero > tol) {
        a.movimientos.add(Movimiento(
            programado: p, real: sale, horas: espero, motivo: 'Esperó a su relevo', con: b.guardia));
      }
    }
    if (sale.isBefore(p)) {
      final antes = _h(p, sale);
      if (antes > tol) {
        a.movimientos.add(Movimiento(
            programado: p, real: sale, horas: -antes, motivo: 'Salió antes del relevo', con: b.guardia));
      }
      final cubrio = _h(p, entra.isAfter(sale) ? entra : sale);
      if (cubrio > tol) {
        b.movimientos.add(Movimiento(
            programado: p, real: entra, horas: cubrio, motivo: 'Entró antes y lo cubrió', con: a.guardia));
      }
    }
  }

  static void _finSinRelevo(RegistroTurno a, double tol) {
    final d = _h(a.fin!, a.progFin!);
    if (d > tol) {
      a.movimientos.add(Movimiento(
          programado: a.progFin!, real: a.fin!, horas: d,
          motivo: 'Se quedó después de su hora (sin relevo registrado)'));
    } else if (d < -tol) {
      a.movimientos.add(Movimiento(
          programado: a.progFin!, real: a.fin!, horas: d,
          motivo: 'Salió antes de su hora (sin relevo registrado)'));
    }
  }

  static void _inicioSinRelevo(RegistroTurno b, double tol) {
    final tarde = _h(b.inicio, b.progInicio!);
    if (tarde > tol) {
      b.movimientos.add(Movimiento(
          programado: b.progInicio!, real: b.inicio, horas: -tarde,
          motivo: 'Llegó tarde (sin relevo registrado)'));
    }
  }

  /// Panel del mes [mes] desde los eventos de la nube, por edificio.
  /// [tolerancias]: minutos por edificio (los que falten usan 15).
  static Map<String, List<PanelPuesto>> panelNube(List<Map<String, dynamic>> eventos, DateTime mes,
      {Map<String, int> tolerancias = const {}}) {
    final nombres = <String, String>{}; // puesto -> "Bloque A"
    for (final e in eventos) {
      final d = e['detalle'];
      final bloque = (d is Map ? d['bloque'] ?? '' : '').toString().trim();
      if (bloque.isNotEmpty) nombres[(e['device_id'] ?? 'sin-celular').toString()] = bloque;
    }
    final porEd = <String, List<RegistroTurno>>{};
    for (final t in desdeEventos(eventos)) {
      porEd.putIfAbsent(t.edificio, () => []).add(t);
    }
    final desde = DateTime(mes.year, mes.month), hasta = DateTime(mes.year, mes.month + 1);
    final out = <String, List<PanelPuesto>>{};
    for (final e in porEd.entries) {
      final p = calcular(e.value,
          nombres: nombres,
          desde: desde,
          hasta: hasta,
          toleranciaMin: tolerancias[e.key] ?? Turnos.toleranciaPorDefecto);
      if (p.isNotEmpty) out[e.key] = p;
    }
    return out;
  }

  /// Une los resúmenes de un guardia de varios puestos (un mismo edificio).
  static Map<String, ResumenGuardia> porGuardia(Iterable<PanelPuesto> puestos) {
    final out = <String, ResumenGuardia>{};
    for (final p in puestos) {
      for (final r in p.guardias.values) {
        out.putIfAbsent(r.guardia, () => ResumenGuardia(r.guardia)).turnos.addAll(r.turnos);
      }
    }
    for (final r in out.values) {
      r.turnos.sort((a, b) => _orden(a, b));
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // LECTURA DE REGISTROS
  // ---------------------------------------------------------------------------

  static int _ordenTipo(String tipo) {
    switch (tipo) {
      case 'Ingreso de turno':
        return 0;
      case 'Doblar turno':
        return 1;
      case 'Salida de turno':
        return 2;
      default:
        return 3; // correcciones al final
    }
  }

  /// Turnos desde los eventos de la NUBE (Ingreso / Salida / Doblar turno /
  /// Corrección de turno) de uno o varios edificios.
  /// - Duplicados: un mismo evento (mismo uid) se usa una vez.
  /// - Fuera de orden: se ordena por la hora REAL (detalle.ts), no la de subida.
  /// - Incompletos: ingreso sin salida → "sin salida"; salida sin ingreso →
  ///   "sin ingreso"; quedan en el historial pero no suman ni restan.
  /// - Correcciones: la ÚLTIMA corrección de cada turno reemplaza sus datos
  ///   (corregir dos veces no suma dos veces).
  static List<RegistroTurno> desdeEventos(List<Map<String, dynamic>> eventos, {DateTime? ahora}) {
    final now = ahora ?? DateTime.now();
    final evs = <_Ev>[];
    final vistos = <String>{};
    for (final e in eventos) {
      final ev = _Ev.de(e);
      if (ev == null) continue;
      if (!vistos.add(ev.uid)) continue; // mismo evento leído dos veces
      evs.add(ev);
    }
    evs.sort((a, b) {
      final c = a.t.compareTo(b.t);
      if (c != 0) return c;
      final o = _ordenTipo(a.tipo).compareTo(_ordenTipo(b.tipo));
      return o != 0 ? o : a.uid.compareTo(b.uid);
    });

    final porRef = <String, RegistroTurno>{};
    final abierto = <String, RegistroTurno>{}; // edificio|guardia -> turno abierto
    final correcciones = <String, _Ev>{};
    String fh(DateTime t) => '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')} '
        '${Turnos.fmtHora(t.hour, t.minute)}';

    for (final ev in evs) {
      final k = '${ev.ed}|${ev.g}';
      final ref = ev.det['turno_ref']?.toString();
      switch (ev.tipo) {
        case 'Ingreso de turno':
          final id = ref ?? 'nube:${ev.uid}';
          if (porRef.containsKey(id)) continue; // el mismo ingreso otra vez
          final prev = abierto[k];
          if (prev != null && prev.fin == null && prev.marca == null) {
            prev.marca = 'sin salida';
            prev.notas.add('No marcó salida (volvió a marcar ingreso el ${fh(ev.t)})');
          }
          final t = RegistroTurno(
            id: id,
            edificio: ev.ed,
            guardia: ev.g,
            puesto: ev.puesto,
            inicio: ev.t,
            relevos: Turnos.limpiar((ev.det['relevos'] ?? '').toString().split(',')),
            refIngreso: ev.ref,
          );
          porRef[id] = t;
          abierto[k] = t;
          break;
        case 'Salida de turno':
        case 'Doblar turno':
          RegistroTurno? t = ref != null ? porRef[ref] : null;
          // Registros viejos (o ingreso marcado con la versión anterior y
          // salida con la nueva): el turno abierto de ese guardia.
          if (t == null) {
            final c = abierto[k];
            if (c != null && c.fin == null && (ref == null || c.id.startsWith('nube:'))) t = c;
          }
          final nivel = Turnos.nivelValido(ev.det['nivel']);
          if (ev.tipo == 'Doblar turno') {
            if (t != null && nivel != null) t.nivelDeclarado = nivel; // el último gana
            break;
          }
          if (t == null) {
            final h = RegistroTurno(
              id: 'salida:${ev.uid}',
              edificio: ev.ed,
              guardia: ev.g,
              puesto: ev.puesto,
              inicio: ev.t,
              fin: ev.t,
              nivelDeclarado: nivel,
              refSalida: ev.ref,
            )..marca = 'sin ingreso';
            h.notas.add('Salida ${fh(ev.t)} sin ingreso registrado');
            porRef[h.id] = h;
            break;
          }
          if (t.fin != null) {
            t.notas.add('Salida repetida ${fh(ev.t)} ignorada');
            break;
          }
          t.fin = ev.t;
          t.refSalida = ev.ref;
          if (nivel != null) t.nivelDeclarado = nivel;
          if (identical(abierto[k], t)) abierto.remove(k);
          break;
        case 'Corrección de turno':
          if (ref != null) correcciones[ref] = ev; // la más reciente gana
          break;
      }
    }

    for (final c in correcciones.entries) {
      final t = porRef[c.key];
      if (t == null) continue;
      final d = c.value.det;
      if (d['anular'] == true) {
        t.marca = 'anulado';
      } else {
        final ini = DateTime.tryParse('${d['inicio'] ?? ''}')?.toLocal();
        final fin = DateTime.tryParse('${d['fin'] ?? ''}')?.toLocal();
        if (ini != null) t.inicio = ini;
        if (fin != null) t.fin = fin;
        final nv = Turnos.nivelValido(d['nivel']);
        if (nv != null) t.nivelDeclarado = nv;
        if (t.marca == 'sin salida' || t.marca == 'sin ingreso') t.marca = null;
      }
      t.corregido = true;
      final motivo = (d['motivo'] ?? '').toString().trim();
      t.notas.add('Corregido ${fh(c.value.t)} por ${c.value.g}${motivo.isEmpty ? '' : ': $motivo'}');
    }

    for (final t in porRef.values) {
      _validar(t, now);
    }
    return porRef.values.toList();
  }

  /// Turnos desde la base LOCAL de este celular (edificios sin conexión).
  static List<RegistroTurno> desdeLocal(
    List<Map<String, dynamic>> ingresos,
    List<Map<String, dynamic>> salidas, {
    required List<String> relevos,
    String edificio = '',
    DateTime? ahora,
  }) {
    final now = ahora ?? DateTime.now();
    final salida = <int, Map<String, dynamic>>{};
    for (final s in salidas) {
      final tid = s['turno_id'];
      if (tid is! int) continue;
      final prev = salida[tid];
      // Si quedó una salida repetida, vale la primera.
      if (prev == null || '${s['created_at']}'.compareTo('${prev['created_at']}') < 0) salida[tid] = s;
    }
    final out = <RegistroTurno>[];
    for (final ing in ingresos) {
      final ini = DateTime.tryParse('${ing['created_at'] ?? ''}');
      if (ini == null) continue;
      final s = salida[ing['id']];
      final t = RegistroTurno(
        id: 'local:${ing['id']}',
        edificio: edificio,
        guardia: (ing['guardia_nombre'] ?? 'Sin nombre').toString(),
        puesto: 'local',
        inicio: ini,
        fin: s == null ? null : DateTime.tryParse('${s['created_at'] ?? ''}'),
        nivelDeclarado: Turnos.nivelValido(ing['nivel']),
        relevos: relevos,
        refIngreso: 'ingreso #${ing['id']}',
        refSalida: s == null ? null : 'salida #${s['id']}',
      );
      if (t.fin == null && (ing['activo'] ?? 0) != 1) {
        t.marca = 'sin salida';
        t.notas.add('No se registró la salida');
      }
      _validar(t, now);
      out.add(t);
    }
    return out;
  }

  static void _validar(RegistroTurno t, DateTime now) {
    if (t.marca != null) return;
    if (t.fin != null) {
      final m = t.fin!.difference(t.inicio).inMinutes;
      if (m <= 0 || m > 60 * 60) {
        t.marca = 'inconsistente';
        t.notas.add('Salida antes del ingreso o turno de más de 60 h: no se calcula');
      }
    } else if (now.difference(t.inicio).inHours > t.nivel + 12) {
      t.marca = 'sin salida';
      t.notas.add('No se registró la salida');
    }
  }
}

/// Evento de la nube ya normalizado.
class _Ev {
  final String tipo, ed, g, puesto, uid, ref;
  final DateTime t;
  final Map det;
  _Ev(this.tipo, this.ed, this.g, this.puesto, this.t, this.det, this.uid, this.ref);

  static const _tipos = {'Ingreso de turno', 'Salida de turno', 'Doblar turno', 'Corrección de turno'};

  static _Ev? de(Map<String, dynamic> e) {
    final tipo = (e['tipo'] ?? '').toString();
    if (!_tipos.contains(tipo)) return null;
    final d = e['detalle'];
    final det = d is Map ? d : const {};
    // Hora REAL del evento: la del celular (ts); en eventos viejos, la de subida.
    final t = DateTime.tryParse('${det['ts'] ?? e['created_at'] ?? ''}')?.toLocal();
    if (t == null) return null;
    final ed = (e['edificio'] ?? 'Sin edificio').toString();
    final g = (e['guardia'] ?? 'Sin nombre').toString();
    final puesto = (e['device_id'] ?? 'sin-celular').toString();
    final idNube = e['id'];
    // uid: el del celular; eventos viejos: id de la nube; si no, una huella.
    final uid = det['uid']?.toString() ??
        (idNube != null
            ? 'id$idNube'
            : '$tipo|$ed|$g|$puesto|${t.toUtc().toIso8601String().substring(0, 16)}');
    final ref = idNube != null ? 'nube #$idNube' : uid;
    return _Ev(tipo, ed, g, puesto, t, det, uid, ref);
  }
}
