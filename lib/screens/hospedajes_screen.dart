import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../theme.dart';
import '../widgets/photo_field.dart';

const _plataformas = ['Airbnb', 'Booking', 'Directo', 'Otro'];

class HospedajesScreen extends StatefulWidget {
  const HospedajesScreen({super.key});
  @override
  State<HospedajesScreen> createState() => _HospedajesScreenState();
}

class _HospedajesScreenState extends State<HospedajesScreen> {
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final rows = await db.query('hospedajes',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'id DESC');
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  Future<void> _finalizar(Map<String, dynamic> x) async {
    final db = await DB.instance.database;
    await db.update('hospedajes', {'estado': 'finalizado'}, where: 'id=?', whereArgs: [x['id']]);
    await Audit.log('EDITAR', 'hospedajes', '${x['id']}', detalle: 'finalizado');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hospedajes')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF00838F),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Nuevo'),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const HospedajeForm()));
          _load();
        },
      ),
      body: _rows.isEmpty
          ? const Center(child: Text('Sin hospedajes'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length,
              itemBuilder: (_, i) {
                final x = _rows[i];
                final activo = x['estado'] == 'activo';
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: (activo ? const Color(0xFF00838F) : Colors.grey).withOpacity(.15),
                      child: Icon(Icons.hotel, color: activo ? const Color(0xFF00838F) : Colors.grey),
                    ),
                    title: Text('Depto ${x['depto']} · ${x['huesped'] ?? ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${x['plataforma'] ?? ''} · ${x['fecha_ingreso'] ?? ''} → ${x['fecha_salida'] ?? ''}\n${x['cantidad'] ?? 1} huesped(es)',
                        maxLines: 3, overflow: TextOverflow.ellipsis),
                    isThreeLine: true,
                    trailing: activo
                        ? TextButton(onPressed: () => _finalizar(x), child: const Text('Cerrar'))
                        : const Icon(Icons.done, color: Colors.grey),
                  ),
                );
              },
            ),
    );
  }
}

class HospedajeForm extends StatefulWidget {
  const HospedajeForm({super.key});
  @override
  State<HospedajeForm> createState() => _HospedajeFormState();
}

class _HospedajeFormState extends State<HospedajeForm> {
  final _huesped = TextEditingController();
  final _doc = TextEditingController();
  final _depto = TextEditingController();
  final _cantidad = TextEditingController(text: '1');
  final _placa = TextEditingController();
  final _obs = TextEditingController();
  String _plataforma = _plataformas.first;
  DateTime? _ingreso;
  DateTime? _salida;
  String? _fotoDoc;
  bool _saving = false;

  Future<void> _pickFecha(bool ingreso) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (d != null) setState(() => ingreso ? _ingreso = d : _salida = d);
  }

  String _fmt(DateTime? d) => d == null ? 'Seleccionar' : DateFormat('dd/MM/yyyy').format(d);

  Future<void> _guardar() async {
    if (_huesped.text.trim().isEmpty || _fotoDoc == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nombre y foto del documento son obligatorios'), backgroundColor: AppColors.rojo));
      return;
    }
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    final id = await db.insert('hospedajes', {
      'guardia_nombre': s.userNombre,
      'plataforma': _plataforma,
      'huesped': _huesped.text.trim(),
      'documento': _doc.text,
      'foto_doc': _fotoDoc,
      'depto': _depto.text,
      'fecha_ingreso': _ingreso == null ? '' : DateFormat('dd/MM/yyyy').format(_ingreso!),
      'fecha_salida': _salida == null ? '' : DateFormat('dd/MM/yyyy').format(_salida!),
      'cantidad': int.tryParse(_cantidad.text) ?? 1,
      'placa': _placa.text,
      'observaciones': _obs.text,
      'estado': 'activo',
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'hospedajes', '$id');
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nuevo Hospedaje')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            value: _plataforma,
            decoration: const InputDecoration(labelText: 'Plataforma'),
            items: [for (final p in _plataformas) DropdownMenuItem(value: p, child: Text(p))],
            onChanged: (v) => setState(() => _plataforma = v ?? _plataforma),
          ),
          const SizedBox(height: 12),
          TextField(controller: _huesped, decoration: const InputDecoration(labelText: 'Huesped principal *')),
          const SizedBox(height: 12),
          TextField(controller: _doc, decoration: const InputDecoration(labelText: 'Documento / pasaporte')),
          const SizedBox(height: 16),
          PhotoField(label: 'Foto del documento', obligatoria: true, onChanged: (v) => _fotoDoc = v),
          TextField(controller: _depto, decoration: const InputDecoration(labelText: 'Departamento')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: () => _pickFecha(true), icon: const Icon(Icons.login, size: 18), label: Text('Ingreso: ${_fmt(_ingreso)}'))),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: () => _pickFecha(false), icon: const Icon(Icons.logout, size: 18), label: Text('Salida: ${_fmt(_salida)}'))),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: _cantidad, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Nro huespedes'))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _placa, decoration: const InputDecoration(labelText: 'Placa vehiculo'))),
          ]),
          const SizedBox(height: 12),
          TextField(controller: _obs, maxLines: 2, decoration: const InputDecoration(labelText: 'Observaciones')),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF00838F)),
            onPressed: _saving ? null : _guardar,
            icon: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.save),
            label: const Text('Guardar hospedaje'),
          ),
        ],
      ),
    );
  }
}
