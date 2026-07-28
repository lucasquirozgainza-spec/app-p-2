import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../theme.dart';
import '../widgets/photo_field.dart';

const _tiposMant = ['Plomeria', 'Electricidad', 'Ascensor', 'Piscina', 'Limpieza', 'Pintura', 'Otro'];

class MantenimientoScreen extends StatefulWidget {
  const MantenimientoScreen({super.key});
  @override
  State<MantenimientoScreen> createState() => _MantenimientoScreenState();
}

class _MantenimientoScreenState extends State<MantenimientoScreen> {
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final rows = await db.query('mantenimiento',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'id DESC');
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  Future<void> _cambiarEstado(Map<String, dynamic> x, String estado) async {
    final db = await DB.instance.database;
    await db.update('mantenimiento', {'estado': estado}, where: 'id=?', whereArgs: [x['id']]);
    await Audit.log('EDITAR', 'mantenimiento', '${x['id']}', detalle: 'estado=$estado');
    _load();
  }

  Color _colorEstado(String? e) {
    switch (e) {
      case 'finalizado':
        return AppColors.verde;
      case 'proceso':
        return const Color(0xFFEF6C00);
      default:
        return AppColors.rojo;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mantenimiento')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF5D4037),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Nuevo'),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const MantenimientoForm()));
          _load();
        },
      ),
      body: _rows.isEmpty
          ? const Center(child: Text('Sin registros de mantenimiento'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length,
              itemBuilder: (_, i) {
                final x = _rows[i];
                final hora = DateFormat('dd/MM HH:mm').format(DateTime.parse(x['created_at'] as String));
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: _colorEstado(x['estado'] as String?).withOpacity(.15),
                      child: Icon(Icons.build, color: _colorEstado(x['estado'] as String?)),
                    ),
                    title: Text('${x['tipo']} · ${x['lugar'] ?? ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${x['observaciones'] ?? ''}\n$hora · ${x['estado']}',
                        maxLines: 3, overflow: TextOverflow.ellipsis),
                    isThreeLine: true,
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) => _cambiarEstado(x, v),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'pendiente', child: Text('Pendiente')),
                        PopupMenuItem(value: 'proceso', child: Text('En proceso')),
                        PopupMenuItem(value: 'finalizado', child: Text('Finalizado')),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class MantenimientoForm extends StatefulWidget {
  const MantenimientoForm({super.key});
  @override
  State<MantenimientoForm> createState() => _MantenimientoFormState();
}

class _MantenimientoFormState extends State<MantenimientoForm> {
  final _lugar = TextEditingController();
  final _obs = TextEditingController();
  String _tipo = _tiposMant.first;
  String? _fotoAntes;
  bool _saving = false;

  Future<void> _guardar() async {
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    final id = await db.insert('mantenimiento', {
      'lugar': _lugar.text,
      'tipo': _tipo,
      'foto_antes': _fotoAntes,
      'observaciones': _obs.text,
      'estado': 'pendiente',
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'mantenimiento', '$id');
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nuevo Mantenimiento')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            value: _tipo,
            decoration: const InputDecoration(labelText: 'Tipo'),
            items: [for (final t in _tiposMant) DropdownMenuItem(value: t, child: Text(t))],
            onChanged: (v) => setState(() => _tipo = v ?? _tipo),
          ),
          const SizedBox(height: 12),
          TextField(controller: _lugar, decoration: const InputDecoration(labelText: 'Lugar')),
          const SizedBox(height: 16),
          PhotoField(label: 'Foto (antes)', onChanged: (v) => _fotoAntes = v),
          TextField(controller: _obs, maxLines: 2, decoration: const InputDecoration(labelText: 'Observaciones')),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF5D4037)),
            onPressed: _saving ? null : _guardar,
            icon: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.save),
            label: const Text('Guardar'),
          ),
        ],
      ),
    );
  }
}
