import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/notify_service.dart';
import '../theme.dart';
import '../widgets/photo_field.dart';
import '../widgets/depto_field.dart';

const _tiposIncidente = ['Seguridad', 'Mantenimiento', 'Accidente', 'Mascotas', 'Ruido', 'Otro'];

class IncidentesScreen extends StatefulWidget {
  const IncidentesScreen({super.key});
  @override
  State<IncidentesScreen> createState() => _IncidentesScreenState();
}

class _IncidentesScreenState extends State<IncidentesScreen> {
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final rows = await db.query('incidentes',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'id DESC');
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  Future<void> _resolver(Map<String, dynamic> x) async {
    final db = await DB.instance.database;
    await db.update('incidentes', {'estado': 'resuelto'}, where: 'id=?', whereArgs: [x['id']]);
    await Audit.log('RESOLVER', 'incidentes', '${x['id']}');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Incidentes')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.rojo,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Reportar'),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const IncidenteForm()));
          _load();
        },
      ),
      body: _rows.isEmpty
          ? const Center(child: Text('Sin incidentes'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length,
              itemBuilder: (_, i) {
                final x = _rows[i];
                final pend = x['estado'] == 'pendiente';
                final hora = DateFormat('dd/MM HH:mm').format(DateTime.parse(x['created_at'] as String));
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: (pend ? AppColors.rojo : AppColors.verde).withOpacity(.15),
                      child: Icon(pend ? Icons.warning_amber : Icons.check_circle,
                          color: pend ? AppColors.rojo : AppColors.verde),
                    ),
                    title: Text('${x['tipo']} · ${x['lugar'] ?? ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${x['descripcion'] ?? ''}\n$hora',
                        maxLines: 3, overflow: TextOverflow.ellipsis),
                    isThreeLine: true,
                    trailing: pend
                        ? TextButton(onPressed: () => _resolver(x), child: const Text('Resolver'))
                        : const Icon(Icons.done, color: Colors.grey),
                  ),
                );
              },
            ),
    );
  }
}

class IncidenteForm extends StatefulWidget {
  const IncidenteForm({super.key});
  @override
  State<IncidenteForm> createState() => _IncidenteFormState();
}

class _IncidenteFormState extends State<IncidenteForm> {
  final _lugar = TextEditingController();
  final _desc = TextEditingController();
  final _involucrados = TextEditingController();
  String _tipo = _tiposIncidente.first;
  final List<String> _fotos = [];
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reportar Incidente')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            value: _tipo,
            decoration: const InputDecoration(labelText: 'Tipo'),
            items: [for (final t in _tiposIncidente) DropdownMenuItem(value: t, child: Text(t))],
            onChanged: (v) => setState(() => _tipo = v ?? _tipo),
          ),
          const SizedBox(height: 12),
          DeptoField(controller: _lugar, label: 'Lugar / Depto'),
          const SizedBox(height: 12),
          TextField(controller: _desc, maxLines: 3, decoration: const InputDecoration(labelText: 'Descripcion *', alignLabelWithHint: true)),
          const SizedBox(height: 12),
          TextField(controller: _involucrados, decoration: const InputDecoration(labelText: 'Personas involucradas')),
          const SizedBox(height: 16),
          PhotoField(label: 'Fotografia', obligatoria: true, album: 'OSIRIS Incidentes', onChanged: (v) {
            if (v != null) setState(() => _fotos.add(v));
          }),
          if (_fotos.length > 1)
            Text('${_fotos.length} fotos agregadas', style: const TextStyle(color: AppColors.verde)),
          const SizedBox(height: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
            onPressed: _saving ? null : _guardar,
            icon: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.save),
            label: const Text('Guardar incidente'),
          ),
        ],
      ),
    );
  }

  Future<void> _guardar() async {
    if (_desc.text.trim().isEmpty || _fotos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Descripcion y al menos una foto son obligatorias'), backgroundColor: AppColors.rojo));
      return;
    }
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    final id = await db.insert('incidentes', {
      'guardia_nombre': s.userNombre,
      'lugar': _lugar.text,
      'tipo': _tipo,
      'descripcion': _desc.text,
      'fotos': jsonEncode(_fotos),
      'involucrados': _involucrados.text,
      'estado': 'pendiente',
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'incidentes', '$id');
    await Cloud.evento('Incidente',
        detalle: {'tipo': _tipo, 'lugar': _lugar.text, 'descripcion': _desc.text});
    // Aviso automático al administrador (correo y/o WhatsApp según config).
    if (mounted) {
      await NotifyService.incidente(
        context,
        tipo: _tipo,
        lugar: _lugar.text,
        descripcion: _desc.text,
        guardia: s.userNombre ?? 'Sin asignar',
      );
    }
    if (!mounted) return;
    Navigator.pop(context);
  }
}
