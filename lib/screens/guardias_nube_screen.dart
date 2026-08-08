import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/cloud.dart';
import '../theme.dart';

/// ADMIN a distancia: horas y días de los guardias de TODOS los edificios,
/// calculado desde los eventos de turno en la nube (mes actual).
class GuardiasNubeScreen extends StatefulWidget {
  const GuardiasNubeScreen({super.key});
  @override
  State<GuardiasNubeScreen> createState() => _GuardiasNubeScreenState();
}

class _Resumen {
  final String guardia;
  final Set<String> dias = {};
  int turnos = 0;
  double horas = 0;
  DateTime? abierto; // ingreso sin salida aún
  _Resumen(this.guardia);
}

class _GuardiasNubeScreenState extends State<GuardiasNubeScreen> {
  bool _loading = true;
  // edificio -> (guardia -> resumen)
  Map<String, Map<String, _Resumen>> _data = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _loading = true);
    final eventos = await Cloud.eventosTurnoMes(); // Ingreso/Salida de turno, todos los edificios
    // Ordenar por fecha ascendente para poder emparejar ingreso->salida.
    eventos.sort((a, b) => (a['created_at'] ?? '').toString().compareTo((b['created_at'] ?? '').toString()));
    final data = <String, Map<String, _Resumen>>{};
    for (final e in eventos) {
      final ed = (e['edificio'] ?? 'Sin edificio').toString();
      final g = (e['guardia'] ?? 'Sin nombre').toString();
      final tipo = (e['tipo'] ?? '').toString();
      DateTime? t;
      try {
        t = DateTime.parse((e['created_at']).toString()).toLocal();
      } catch (_) {}
      final porEd = data.putIfAbsent(ed, () => {});
      final r = porEd.putIfAbsent(g, () => _Resumen(g));
      if (tipo == 'Ingreso de turno') {
        if (t != null) {
          r.dias.add(DateFormat('yyyy-MM-dd').format(t));
          r.abierto = t;
        }
        r.turnos++;
      } else if (tipo == 'Salida de turno') {
        if (t != null && r.abierto != null) {
          final h = t.difference(r.abierto!).inMinutes / 60.0;
          if (h > 0 && h < 24) r.horas += h;
          r.abierto = null;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _data = data;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final edificios = _data.keys.toList()..sort();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Guardias (todos los edificios)'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _cargar)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : edificios.isEmpty
              ? const Center(child: Padding(padding: EdgeInsets.all(24),
                  child: Text('Sin turnos registrados este mes en la nube.', textAlign: TextAlign.center)))
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
                      child: Text('Horas y días de este mes, calculados desde la nube.',
                          style: TextStyle(fontSize: 12, color: Colors.black54)),
                    ),
                    for (final ed in edificios) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
                        child: Row(children: [
                          const Icon(Icons.apartment, color: AppColors.azulMarino, size: 20),
                          const SizedBox(width: 6),
                          Text(ed, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppColors.azulMarino)),
                        ]),
                      ),
                      for (final r in (_data[ed]!.values.toList()..sort((a, b) => b.horas.compareTo(a.horas))))
                        Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: AppColors.verde.withOpacity(.12),
                              child: Text('${r.dias.length}',
                                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.verde)),
                            ),
                            title: Text(r.guardia, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text('${r.dias.length} días · ${r.turnos} turnos · ${r.horas.toStringAsFixed(1)} h'),
                          ),
                        ),
                    ],
                  ],
                ),
    );
  }
}
