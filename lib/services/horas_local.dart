import '../db/database_helper.dart';
import 'app_state.dart';
import 'cloud.dart';
import 'panel_horas.dart';

class HorasEdificio {
  final List<PanelPuesto> puestos;
  final bool local; // true = solo lo de este celular (sin nube o sin señal)
  HorasEdificio(this.puestos, this.local);
}

/// Origen ÚNICO de las horas de un edificio para pantallas y reportes.
/// Todos usan el mismo cálculo (PanelHoras), así ningún reporte da un número
/// distinto al de la tarjeta del guardia.
class HorasPanel {
  /// Horas del edificio activo en el mes: desde la nube (todos los celulares
  /// del edificio) o, en edificios sin conexión o sin señal, desde este
  /// celular. [local] indica de dónde salieron.
  static Future<HorasEdificio> edificio(DateTime mes) async {
    final s = AppState.instance;
    if (!s.soloLocal) {
      try {
        await Cloud.vaciarCola(); // lo propio pendiente cuenta ya
        final ev = await Cloud.eventosTurnoMes(mes: mes, edificio: s.edificioId, lanzar: true);
        final p = PanelHoras.panelNube(ev, mes, tolerancias: {s.edificioId: s.toleranciaMin});
        return HorasEdificio(p[s.edificioId] ?? <PanelPuesto>[], false);
      } catch (_) {
        // Sin señal: lo de este celular (se avisa en pantalla / PDF).
      }
    }
    return HorasEdificio(await local(mes), true);
  }

  /// Turnos guardados en ESTE celular.
  static Future<List<PanelPuesto>> local(DateTime mes) async {
    final db = await DB.instance.database;
    final s = AppState.instance;
    final desde = DateTime(mes.year, mes.month);
    final hasta = DateTime(mes.year, mes.month + 1);
    // Días del borde para saber quién relevó a quién (turnos de hasta 36 h).
    final di = desde.subtract(const Duration(days: 2)).toIso8601String();
    final ha = hasta.add(const Duration(days: 2)).toIso8601String();
    final ingresos = await db.query('ingreso_turno',
        where: 'edificio=? AND created_at>=? AND created_at<?',
        whereArgs: [s.edificioId, di, ha],
        orderBy: 'created_at');
    final ids = [for (final i in ingresos) if (i['id'] is int) i['id'] as int];
    // Rango de ids (sin límite de parámetros de SQLite); lo que no es de
    // estos ingresos simplemente no se usa.
    final salidas = ids.isEmpty
        ? <Map<String, dynamic>>[]
        : await db.query('salida_turno',
            where: 'turno_id BETWEEN ? AND ?',
            whereArgs: [ids.reduce((a, b) => a < b ? a : b), ids.reduce((a, b) => a > b ? a : b)]);
    final regs = PanelHoras.desdeLocal(ingresos, salidas, relevos: s.horarios, edificio: s.edificioId);
    return PanelHoras.calcular(regs,
        nombres: {'local': s.bloque.isNotEmpty ? s.bloque : 'Este celular'},
        desde: desde,
        hasta: hasta,
        toleranciaMin: s.toleranciaMin);
  }
}
