import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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

    // UNA sola consulta con sub-consultas (antes 16 consultas una tras otra).
    // ?1 = edificio, ?2 = hoy, ?3 = desde.
    const vivoSql = {
      'dentro': "SELECT COUNT(*) FROM visitas WHERE edificio=?1 AND estado='dentro'",
      'encomiendas': "SELECT COUNT(*) FROM encomiendas WHERE edificio=?1 AND estado='pendiente'",
      'incidentes': "SELECT COUNT(*) FROM incidentes WHERE edificio=?1 AND estado='pendiente'",
      'mantenimiento': "SELECT COUNT(*) FROM mantenimiento WHERE edificio=?1 AND estado!='finalizado'",
      'hospedajes': "SELECT COUNT(*) FROM hospedajes WHERE edificio=?1 AND estado='activo'",
      'guardias': "SELECT COUNT(*) FROM ingreso_turno WHERE edificio=?1 AND activo=1",
      'rondas_hoy': "SELECT COUNT(*) FROM rondas WHERE edificio=?1 AND substr(created_at,1,10)=?2",
      'vehiculos': "SELECT COUNT(*) FROM vehiculos WHERE edificio=?1",
      'propietarios': "SELECT COUNT(*) FROM propietarios WHERE edificio=?1",
    };
    const perTablas = {
      'Visitas': 'visitas', 'Rondas': 'rondas', 'Incidentes': 'incidentes',
      'Encomiendas': 'encomiendas', 'Mantenimiento': 'mantenimiento',
      'Hospedajes': 'hospedajes', 'Ingresos de turno': 'ingreso_turno',
    };
    final cols = <String>[
      for (final e in vivoSql.entries) '(${e.value}) AS v_${e.key}',
      for (int i = 0; i < perTablas.length; i++)
        '(SELECT COUNT(*) FROM ${perTablas.values.elementAt(i)} WHERE edificio=?1 AND created_at>=?3) AS p_$i',
    ];
    final fila = (await db.rawQuery('SELECT ${cols.join(', ')}', [ed, hoy, desde])).first;
    int n(String k) => (fila[k] as num?)?.toInt() ?? 0;
    final vivo = {for (final k in vivoSql.keys) k: n('v_$k')};
    final per = {
      for (int i = 0; i < perTablas.length; i++) perTablas.keys.elementAt(i): n('p_$i'),
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

  // Módulo asociado a cada fila del periodo (para ocultar los desactivados).
  final _moduloPeriodo = const {
    'Visitas': 'visitas', 'Rondas': 'rondas', 'Incidentes': 'incidentes',
    'Encomiendas': 'encomiendas', 'Mantenimiento': 'mantenimiento',
    'Hospedajes': 'hospedajes', 'Ingresos de turno': '_core',
  };

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    // Solo se muestran las tarjetas de los módulos ACTIVOS en este edificio.
    // Guardias/turnos son parte del núcleo y siempre se ven.
    final live = <Widget>[
      if (s.modulo('visitas'))
        _liveTile(Icons.people_alt, '${_vivo['dentro'] ?? 0}', 'Dentro ahora', AppColors.verde, () => const VisitasScreen()),
      if (s.modulo('encomiendas'))
        _liveTile(Icons.inventory_2, '${_vivo['encomiendas'] ?? 0}', 'Encomiendas pend.', const Color(0xFFEF6C00), () => const EncomiendasScreen()),
      if (s.modulo('incidentes'))
        _liveTile(Icons.warning_amber, '${_vivo['incidentes'] ?? 0}', 'Incidentes abiertos', AppColors.rojo, () => const IncidentesScreen()),
      if (s.modulo('mantenimiento'))
        _liveTile(Icons.build, '${_vivo['mantenimiento'] ?? 0}', 'Mantenim. pend.', const Color(0xFF5D4037), () => const MantenimientoScreen()),
      if (s.modulo('hospedajes'))
        _liveTile(Icons.hotel, '${_vivo['hospedajes'] ?? 0}', 'Hospedajes activos', const Color(0xFF00838F), () => const HospedajesScreen()),
      _liveTile(Icons.shield, '${_vivo['guardias'] ?? 0}', 'Guardias activos', AppColors.verde, () => const GuardiasScreen()),
      if (s.modulo('rondas'))
        _liveTile(Icons.directions_walk, '${_vivo['rondas_hoy'] ?? 0}', 'Rondas hoy', const Color(0xFF6A1B9A), () => const RondasHistorialScreen()),
      if (s.modulo('vehiculos'))
        _liveTile(Icons.directions_car, '${_vivo['vehiculos'] ?? 0}', 'Vehiculos', const Color(0xFF283593), () => const VehiculosScreen()),
      if (s.modulo('propietarios'))
        _liveTile(Icons.people, '${_vivo['propietarios'] ?? 0}', 'Propietarios', const Color(0xFF1565C0), () => const PropietariosScreen()),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Panel / Reportes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'Exportar PDF del periodo',
            onPressed: () {
              const labels = {'dia': 'Hoy', 'semana': 'Semana', 'mes': 'Mes', 'anio': 'Año'};
              conEspera(context, () => PdfExport.informe(desde: _desde, periodo: labels[_periodo] ?? ''));
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
                  if (live.length == 1)
                    SizedBox(width: double.infinity, height: 110, child: live.first)
                  else
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
                    showSelectedIcon: false, // sin el check: el texto no se parte
                    style: SegmentedButton.styleFrom(backgroundColor: Colors.white),
                    segments: const [
                      ButtonSegment(value: 'dia', label: Text('Hoy')),
                      ButtonSegment(value: 'semana', label: Text('Semana')),
                      ButtonSegment(value: 'mes', label: Text('Mes')),
                      ButtonSegment(value: 'anio', label: Text('Año')),
                    ],
                    selected: {_periodo},
                    onSelectionChanged: (s) {
                      setState(() => _periodo = s.first);
                      _load();
                    },
                  ),
                  const SizedBox(height: 10),
                  for (final e in _periodoConteo.entries)
                    if (_moduloPeriodo[e.key] == '_core' || s.modulo(_moduloPeriodo[e.key] ?? ''))
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
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: AppColors.rojo, minimumSize: const Size.fromHeight(48)),
                      onPressed: () => conEspera(context,
                          () => PdfExport.informeMensual(mes: DateTime(DateTime.now().year, DateTime.now().month))),
                      icon: const Icon(Icons.description),
                      label: const Text('Informe mensual (PDF)'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(14),
                      child: Text(
                        'El informe mensual incluye totales, visitas por departamento, incidentes, '
                        'mantenimiento, encomiendas, hospedajes y rondas. El botón PDF de arriba exporta el periodo elegido.',
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
