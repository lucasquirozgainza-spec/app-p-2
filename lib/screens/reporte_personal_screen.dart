import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../theme.dart';

/// Reporte de personal por mes: días trabajados, horas totales,
/// turnos de 24h (doble turno) y horas extra (más de 12h por turno).
class ReportePersonalScreen extends StatefulWidget {
  const ReportePersonalScreen({super.key});
  @override
  State<ReportePersonalScreen> createState() => _ReportePersonalScreenState();
}

class _Resumen {
  String nombre;
  final Set<String> dias = {};
  double horas = 0;
  int dobles = 0;
  double extra = 0;
  int turnos = 0;
  int abiertos = 0;
  _Resumen(this.nombre);
}

class _ReportePersonalScreenState extends State<ReportePersonalScreen> {
  DateTime _mes = DateTime(DateTime.now().year, DateTime.now().month);
  List<_Resumen> _data = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  void _cambiarMes(int delta) {
    setState(() => _mes = DateTime(_mes.year, _mes.month + delta));
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _loading = true);
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final desde = DateTime(_mes.year, _mes.month, 1);
    final hasta = DateTime(_mes.year, _mes.month + 1, 1);
    final di = desde.toIso8601String();
    final ha = hasta.toIso8601String();

    final ingresos = await db.query('ingreso_turno',
        where: 'edificio=? AND created_at>=? AND created_at<?',
        whereArgs: [ed, di, ha], orderBy: 'created_at');
    final salidas = await db.query('salida_turno', where: 'edificio=?', whereArgs: [ed]);
    final salidaPorTurno = <int, String>{};
    for (final s in salidas) {
      if (s['turno_id'] != null) salidaPorTurno[s['turno_id'] as int] = s['created_at'] as String;
    }

    final mapa = <String, _Resumen>{};
    for (final ing in ingresos) {
      final nombre = (ing['guardia_nombre']?.toString() ?? 'Sin nombre');
      final r = mapa.putIfAbsent(nombre, () => _Resumen(nombre));
      final inicio = DateTime.parse(ing['created_at'] as String);
      r.dias.add(DateFormat('yyyy-MM-dd').format(inicio));
      r.turnos++;
      final salStr = salidaPorTurno[ing['id']];
      if (salStr != null) {
        final fin = DateTime.parse(salStr);
        final horas = fin.difference(inicio).inMinutes / 60.0;
        if (horas > 0 && horas < 48) {
          r.horas += horas;
          if (horas >= 20) r.dobles++;
          // Turno normal = 12 h; lo que pase de 12 h es hora extra.
          if (horas > AppState.horasTurno) r.extra += (horas - AppState.horasTurno);
        }
      } else {
        r.abiertos++;
      }
    }
    final list = mapa.values.toList()..sort((a, b) => b.horas.compareTo(a.horas));
    if (!mounted) return;
    setState(() {
      _data = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reporte de personal')),
      body: Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(onPressed: () => _cambiarMes(-1), icon: const Icon(Icons.chevron_left)),
                Text(DateFormat('MMMM yyyy', 'es').format(_mes).toUpperCase(),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                IconButton(onPressed: () => _cambiarMes(1), icon: const Icon(Icons.chevron_right)),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _data.isEmpty
                    ? const Center(child: Text('Sin turnos registrados este mes'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _data.length,
                        itemBuilder: (_, i) {
                          final r = _data[i];
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    const CircleAvatar(
                                        backgroundColor: Color(0x1A0A335D),
                                        child: Icon(Icons.shield, color: AppColors.azulMarino)),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(r.nombre,
                                          maxLines: 1, overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                    ),
                                  ]),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _chip('Dias', '${r.dias.length}', AppColors.azulMarino),
                                      _chip('Horas', r.horas.toStringAsFixed(1), AppColors.verde),
                                      _chip('Turnos 24h', '${r.dobles}', const Color(0xFF6A1B9A)),
                                      _chip('Horas extra', r.extra.toStringAsFixed(1), const Color(0xFFEF6C00)),
                                      if (r.abiertos > 0) _chip('En turno', '${r.abiertos}', Colors.teal),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: color)),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ],
      ),
    );
  }
}
