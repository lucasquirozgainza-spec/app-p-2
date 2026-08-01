import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../widgets/eventos_remotos.dart';

/// Historial de rondas: lista de rondas guardadas; al tocar una se ven las fotos.
class RondasHistorialScreen extends StatefulWidget {
  const RondasHistorialScreen({super.key});
  @override
  State<RondasHistorialScreen> createState() => _RondasHistorialScreenState();
}

class _RondasHistorialScreenState extends State<RondasHistorialScreen> {
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final rows = await db.query('rondas',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'id DESC');
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  List<String> _fotosDe(Map<String, dynamic> r) {
    try {
      final data = jsonDecode(r['puntos']?.toString() ?? '{}');
      final f = data is Map ? data['fotos_ronda'] : null;
      if (f is List) return f.map((e) => e.toString()).toList();
    } catch (_) {}
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Historial de Rondas')),
      body: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length + 1,
              itemBuilder: (_, i) {
                if (i == _rows.length) {
                  return const EventosRemotos(tipo: 'Ronda', icon: Icons.directions_walk,
                      color: Color(0xFF6A1B9A), tituloKeys: ['fotos', 'puntos']);
                }
                final r = _rows[i];
                final fotos = _fotosDe(r);
                final fecha = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(r['created_at'] as String));
                return Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                        backgroundColor: Color(0x1A6A1B9A),
                        child: Icon(Icons.directions_walk, color: Color(0xFF6A1B9A))),
                    title: Text(r['guardia_nombre']?.toString() ?? 'Guardia',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('$fecha · ${fotos.length} fotos'
                        '${(r['observaciones']?.toString().isNotEmpty ?? false) ? '\n${r['observaciones']}' : ''}'),
                    isThreeLine: (r['observaciones']?.toString().isNotEmpty ?? false),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(context, MaterialPageRoute(
                        builder: (_) => _RondaDetalle(ronda: r, fotos: fotos))),
                  ),
                );
              },
            ),
    );
  }
}

class _RondaDetalle extends StatelessWidget {
  final Map<String, dynamic> ronda;
  final List<String> fotos;
  const _RondaDetalle({required this.ronda, required this.fotos});

  @override
  Widget build(BuildContext context) {
    final fecha = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(ronda['created_at'] as String));
    return Scaffold(
      appBar: AppBar(title: const Text('Ronda')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(child: Column(children: [
            ListTile(title: const Text('Guardia'), subtitle: Text(ronda['guardia_nombre']?.toString() ?? '')),
            ListTile(title: const Text('Fecha y hora'), subtitle: Text(fecha)),
            if (ronda['observaciones']?.toString().isNotEmpty ?? false)
              ListTile(title: const Text('Observaciones'), subtitle: Text(ronda['observaciones'].toString())),
          ])),
          const SizedBox(height: 8),
          Text('Fotos (${fotos.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [
              for (final f in fotos)
                if (File(f).existsSync())
                  GestureDetector(
                    onTap: () => showDialog(context: context, builder: (_) => Dialog(
                      child: InteractiveViewer(child: Image.file(File(f))))),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(File(f), fit: BoxFit.cover),
                    ),
                  ),
            ],
          ),
          if (fotos.every((f) => !File(f).existsSync()))
            const Padding(padding: EdgeInsets.all(16),
                child: Text('Las fotos se guardaron en el celular donde se hizo la ronda.',
                    style: TextStyle(color: Colors.black54))),
        ],
      ),
    );
  }
}
