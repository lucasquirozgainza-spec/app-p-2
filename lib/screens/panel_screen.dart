import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

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

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      StatTile(icon: Icons.login, value: '${stats['visitas_hoy'] ?? 0}', label: 'Visitas hoy', color: AppColors.azulMarino),
      StatTile(icon: Icons.people_alt, value: '${stats['dentro'] ?? 0}', label: 'Dentro ahora', color: AppColors.verde),
      StatTile(icon: Icons.directions_walk, value: '${stats['rondas_hoy'] ?? 0}', label: 'Rondas hoy', color: const Color(0xFF6A1B9A)),
      StatTile(icon: Icons.hotel, value: '${stats['hospedajes'] ?? 0}', label: 'Hospedajes activos', color: const Color(0xFF00838F)),
      StatTile(icon: Icons.inventory_2, value: '${stats['encomiendas'] ?? 0}', label: 'Encomiendas pend.', color: const Color(0xFFEF6C00)),
      StatTile(icon: Icons.warning_amber, value: '${stats['incidentes'] ?? 0}', label: 'Incidentes abiertos', color: AppColors.rojo),
      StatTile(icon: Icons.build, value: '${stats['mantenimiento'] ?? 0}', label: 'Mantenim. pend.', color: const Color(0xFF5D4037)),
      StatTile(icon: Icons.directions_car, value: '${stats['vehiculos'] ?? 0}', label: 'Vehiculos', color: const Color(0xFF283593)),
      StatTile(icon: Icons.people, value: '${stats['propietarios'] ?? 0}', label: 'Propietarios', color: const Color(0xFF1565C0)),
      StatTile(icon: Icons.shield, value: '${stats['guardias'] ?? 0}', label: 'Guardias activos', color: AppColors.verde),
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
