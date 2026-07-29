import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
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

class PanelScreen extends StatefulWidget {
  const PanelScreen({super.key});
  @override
  State<PanelScreen> createState() => _PanelScreenState();
}

class _PanelScreenState extends State<PanelScreen> {
  Map<String, int> stats = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final hoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
    Future<int> c(String sql, List a) async =>
        Sqflite.firstIntValue(await db.rawQuery(sql, a)) ?? 0;

    final r = {
      'visitas_hoy': await c("SELECT COUNT(*) FROM visitas WHERE edificio=? AND substr(created_at,1,10)=?", [ed, hoy]),
      'dentro': await c("SELECT COUNT(*) FROM visitas WHERE edificio=? AND estado='dentro'", [ed]),
      'rondas_hoy': await c("SELECT COUNT(*) FROM rondas WHERE edificio=? AND substr(created_at,1,10)=?", [ed, hoy]),
      'hospedajes': await c("SELECT COUNT(*) FROM hospedajes WHERE edificio=? AND estado='activo'", [ed]),
      'encomiendas': await c("SELECT COUNT(*) FROM encomiendas WHERE edificio=? AND estado='pendiente'", [ed]),
      'incidentes': await c("SELECT COUNT(*) FROM incidentes WHERE edificio=? AND estado='pendiente'", [ed]),
      'mantenimiento': await c("SELECT COUNT(*) FROM mantenimiento WHERE edificio=? AND estado!='finalizado'", [ed]),
      'vehiculos': await c("SELECT COUNT(*) FROM vehiculos WHERE edificio=?", [ed]),
      'propietarios': await c("SELECT COUNT(*) FROM propietarios WHERE edificio=?", [ed]),
      'guardias': await c("SELECT COUNT(*) FROM ingreso_turno WHERE edificio=? AND activo=1", [ed]),
    };
    if (!mounted) return;
    setState(() {
      stats = r;
      _loading = false;
    });
  }

  Widget _tile(IconData icon, String value, String label, Color color, Widget Function() builder) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => builder())),
      child: StatTile(icon: icon, value: value, label: label, color: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      _tile(Icons.login, '${stats['visitas_hoy'] ?? 0}', 'Visitas hoy', AppColors.azulMarino, () => const VisitasScreen()),
      _tile(Icons.people_alt, '${stats['dentro'] ?? 0}', 'Dentro ahora', AppColors.verde, () => const VisitasScreen()),
      _tile(Icons.directions_walk, '${stats['rondas_hoy'] ?? 0}', 'Rondas hoy', const Color(0xFF6A1B9A), () => const RondasHistorialScreen()),
      _tile(Icons.hotel, '${stats['hospedajes'] ?? 0}', 'Hospedajes activos', const Color(0xFF00838F), () => const HospedajesScreen()),
      _tile(Icons.inventory_2, '${stats['encomiendas'] ?? 0}', 'Encomiendas pend.', const Color(0xFFEF6C00), () => const EncomiendasScreen()),
      _tile(Icons.warning_amber, '${stats['incidentes'] ?? 0}', 'Incidentes abiertos', AppColors.rojo, () => const IncidentesScreen()),
      _tile(Icons.build, '${stats['mantenimiento'] ?? 0}', 'Mantenim. pend.', const Color(0xFF5D4037), () => const MantenimientoScreen()),
      _tile(Icons.directions_car, '${stats['vehiculos'] ?? 0}', 'Vehiculos', const Color(0xFF283593), () => const VehiculosScreen()),
      _tile(Icons.people, '${stats['propietarios'] ?? 0}', 'Propietarios', const Color(0xFF1565C0), () => const PropietariosScreen()),
      _tile(Icons.shield, '${stats['guardias'] ?? 0}', 'Guardias activos', AppColors.verde, () => const GuardiasScreen()),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Panel / Resumen')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Text('Resumen de ${AppState.instance.edificioNombre}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  for (final t in tiles)
                    Padding(padding: const EdgeInsets.only(bottom: 8), child: t),
                ],
              ),
            ),
    );
  }
}
