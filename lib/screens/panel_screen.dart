import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/pdf_export.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'visitas_screen.dart';
import 'rondas_historial_screen.dart';
import 'hospedajes_screen.dart';
import 'encomiendas_screen.dart';
import 'incidentes_screen.dart';
import 'mantenimiento_screen.dart';
import 'vehiculos_screen.dart';
import 'propietarios_screen.dart';
import 'guardias_screen.dart';

/// Panel unificado: estado en vivo (interactivo) + reportes por periodo con
/// exportacion a PDF. Cada tarjeta lleva al historial de ese modulo.
class PanelScreen extends StatefulWidget {
  const PanelScreen({super.key});
  @override
  State<PanelScreen> createState() => _PanelScreenState();
}

class _PanelScreenState extends State<PanelScreen> {
  String _periodo = 'dia'; // dia | semana | mes | anio
  Map<String, int> _vivo = {};
  Map<String, int> _periodoConteo = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
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

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final hoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final desde = _desde.toIso8601String();

    Future<int> c(String sql, List a) async =>
        Sqflite.firstIntValue(await db.rawQuery(sql, a)) ?? 0;
    Future<int> periodo(String tabla) async => c(
        "SELECT COUNT(*) FROM $tabla WHERE edificio=? AND created_at>=?", [ed, desde]);

    final vivo = {
      'dentro': await c("SELECT COUNT(*) FROM visitas WHERE edificio=? AND estado='dentro'", [ed]),
      'encomiendas': await c("SELECT COUNT(*) FROM encomiendas WHERE edificio=? AND estado='pendiente'", [ed]),
      'incidentes': await c("SELECT COUNT(*) FROM incidentes WHERE edificio=? AND estado='pendiente'", [ed]),
      'mantenimiento': await c("SELECT COUNT(*) FROM mantenimiento WHERE edificio=? AND estado!='finalizado'", [ed]),
      'hospedajes': await c("SELECT COUNT(*) FROM hospedajes WHERE edificio=? AND estado='activo'", [ed]),
      'guardias': await c("SELECT COUNT(*) FROM ingreso_turno WHERE edificio=? AND activo=1", [ed]),
      'rondas_hoy': await c("SELECT COUNT(*) FROM rondas WHERE edificio=? AND substr(created_at,1,10)=?", [ed, hoy]),
      'vehiculos': await c("SELECT COUNT(*) FROM vehiculos WHERE edificio=?", [ed]),
      'propietarios': await c("SELECT COUNT(*) FROM propietarios WHERE edificio=?", [ed]),
    };
    final per = {
      'Visitas': await periodo('visitas'),
      'Rondas': await periodo('rondas'),
      'Incidentes': await periodo('incidentes'),
      'Encomiendas': await periodo('encomiendas'),
      'Mantenimiento': await periodo('mantenimiento'),
      'Hospedajes': await periodo('hospedajes'),
      'Ingresos de turno': await periodo('ingreso_turno'),
    };
    if (!mounted) return;
    setState(() {
      _vivo = vivo;
      _periodoConteo = per;
      _loading = false;
    });
  }

  void _ir(Widget Function() b) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => b()));

  final _iconosPeriodo = const {
    'Visitas': Icons.badge, 'Rondas': Icons.directions_walk, 'Incidentes': Icons.warning_amber,
    'Encomiendas': Icons.inventory_2, 'Mantenimiento': Icons.build, 'Hospedajes': Icons.hotel,
    'Ingresos de turno': Icons.login,
  };

  final _destinoPeriodo = <String, Widget Function()>{
    'Visitas': () => const VisitasScreen(),
    'Rondas': () => const RondasHistorialScreen(),
    'Incidentes': () => const IncidentesScreen(),
    'Encomiendas': () => const EncomiendasScreen(),
    'Mantenimiento': () => const MantenimientoScreen(),
    'Hospedajes': () => const HospedajesScreen(),
    'Ingresos de turno': () => const GuardiasScreen(),
  };

  Widget _liveTile(IconData icon, String value, String label, Color color, Widget Function() b) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _ir(b),
      child: StatTile(icon: icon, value: value, label: label, color: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    final live = <Widget>[
      _liveTile(Icons.people_alt, '${_vivo['dentro'] ?? 0}', 'Dentro ahora', AppColors.verde, () => const VisitasScreen()),
      _liveTile(Icons.inventory_2, '${_vivo['encomiendas'] ?? 0}', 'Encomiendas pend.', const Color(0xFFEF6C00), () => const EncomiendasScreen()),
      _liveTile(Icons.warning_amber, '${_vivo['incidentes'] ?? 0}', 'Incidentes abiertos', AppColors.rojo, () => const IncidentesScreen()),
      _liveTile(Icons.build, '${_vivo['mantenimiento'] ?? 0}', 'Mantenim. pend.', const Color(0xFF5D4037), () => const MantenimientoScreen()),
      _liveTile(Icons.hotel, '${_vivo['hospedajes'] ?? 0}', 'Hospedajes activos', const Color(0xFF00838F), () => const HospedajesScreen()),
      _liveTile(Icons.shield, '${_vivo['guardias'] ?? 0}', 'Guardias activos', AppColors.verde, () => const GuardiasScreen()),
      _liveTile(Icons.directions_walk, '${_vivo['rondas_hoy'] ?? 0}', 'Rondas hoy', const Color(0xFF6A1B9A), () => const RondasHistorialScreen()),
      _liveTile(Icons.directions_car, '${_vivo['vehiculos'] ?? 0}', 'Vehiculos', const Color(0xFF283593), () => const VehiculosScreen()),
      _liveTile(Icons.people, '${_vivo['propietarios'] ?? 0}', 'Propietarios', const Color(0xFF1565C0), () => const PropietariosScreen()),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Panel / Reportes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'Exportar PDF del periodo',
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Text('Resumen de ${AppState.instance.edificioNombre}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('Toca cualquier tarjeta para ver el detalle',
                      style: TextStyle(color: Colors.black54, fontSize: 12)),
                  const SizedBox(height: 10),
                  GridView.extent(
                    maxCrossAxisExtent: 200,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 1.5,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    children: live,
                  ),
                  const SizedBox(height: 18),
                  const Text('Actividad del periodo',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
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
                      _load();
                    },
                  ),
                  const SizedBox(height: 10),
                  for (final e in _periodoConteo.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () {
                          final b = _destinoPeriodo[e.key];
                          if (b != null) _ir(b);
                        },
                        child: StatTile(
                          icon: _iconosPeriodo[e.key] ?? Icons.bar_chart,
                          value: '${e.value}',
                          label: e.key,
                          color: AppColors.azulMarino,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(14),
                      child: Text(
                        'Usa el botón PDF (arriba a la derecha) para exportar y compartir '
                        'el informe completo del periodo.',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
