import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../theme.dart';

/// Historial de advertencias (ej. tarjetas de visita no devueltas).
class AdvertenciasScreen extends StatefulWidget {
  const AdvertenciasScreen({super.key});
  @override
  State<AdvertenciasScreen> createState() => _AdvertenciasScreenState();
}

class _AdvertenciasScreenState extends State<AdvertenciasScreen> {
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final rows = await db.query('advertencias',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'id DESC');
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Advertencias')),
      body: _rows.isEmpty
          ? const Center(child: Text('Sin advertencias registradas'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length,
              itemBuilder: (_, i) {
                final a = _rows[i];
                final fecha = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(a['created_at'] as String));
                return Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                        backgroundColor: Color(0x1AC62828),
                        child: Icon(Icons.warning_amber, color: AppColors.rojo)),
                    title: Text(a['mensaje']?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${a['guardia_nombre'] ?? ''} · $fecha'),
                  ),
                );
              },
            ),
    );
  }
}
