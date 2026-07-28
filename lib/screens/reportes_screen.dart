import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/pdf_export.dart';
import '../theme.dart';
import '../widgets/common.dart';

class ReportesScreen extends StatefulWidget {
  const ReportesScreen({super.key});
  @override
  State<ReportesScreen> createState() => _ReportesScreenState();
}

class _ReportesScreenState extends State<ReportesScreen> {
  String _periodo = 'dia'; // dia | semana | mes | anio
  Map<String, int> _conteos = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  DateTime get _desde {
    final n = DateTime.now();
    switch (_periodo) {
      case 'semana':
        return n.subtract(const Duration(days: 7));
      case 'mes':
        return DateTime(n.year, n.month - 1, n.day);
      case 'anio':
        return DateTime(n.year - 1, n.month, n.day);
      default:
        return DateTime(n.year, n.month, n.day);
    }
  }

  Future<void> _cargar() async {
    setState(() => _loading = true);
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final desde = _desde.toIso8601String();
    Future<int> c(String tabla, [String extra = '']) async =>
        Sqflite.firstIntValue(await db.rawQuery(
            "SELECT COUNT(*) FROM $tabla WHERE edificio=? AND created_at>=? $extra", [ed, desde])) ?? 0;

    final r = {
      'Visitas': await c('visitas'),
      'Rondas': await c('rondas'),
      'Incidentes': await c('incidentes'),
      'Encomiendas': await c('encomiendas'),
      'Mantenimiento': await c('mantenimiento'),
      'Hospedajes': await c('hospedajes'),
      'Ingresos de turno': await c('ingreso_turno'),
    };
    if (!mounted) return;
    setState(() {
      _conteos = r;
      _loading = false;
    });
  }

  final _iconos = const {
    'Visitas': Icons.badge, 'Rondas': Icons.directions_walk, 'Incidentes': Icons.warning_amber,
    'Encomiendas': Icons.inventory_2, 'Mantenimiento': Icons.build, 'Hospedajes': Icons.hotel,
    'Ingresos de turno': Icons.login,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reportes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'Exportar PDF',
            onPressed: () async {
              final labels = {'dia': 'Hoy', 'semana': 'Semana', 'mes': 'Mes', 'anio': 'Ano'};
              try {
                await PdfExport.informe(desde: _desde, periodo: labels[_periodo] ?? '');
              } catch (_) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('No se pudo generar el PDF')));
                }
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<String>(
              style: SegmentedButton.styleFrom(backgroundColor: Colors.white),
              segments: const [
                ButtonSegment(value: 'dia', label: Text('Hoy')),
                ButtonSegment(value: 'semana', label: Text('Semana')),
                ButtonSegment(value: 'mes', label: Text('Mes')),
                ButtonSegment(value: 'anio', label: Text('Ano')),
              ],
              selected: {_periodo},
              onSelectionChanged: (s) {
                setState(() => _periodo = s.first);
                _cargar();
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final e in _conteos.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: StatTile(
                            icon: _iconos[e.key] ?? Icons.bar_chart,
                            value: '${e.value}',
                            label: e.key,
                            color: AppColors.azulMarino,
                          ),
                        ),
                      const SizedBox(height: 12),
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(14),
                          child: Text(
                            'Usa el boton PDF (arriba a la derecha) para exportar el informe '
                            'completo del periodo y compartirlo.',
                            style: TextStyle(color: Colors.black54),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
