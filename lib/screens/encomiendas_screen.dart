import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../theme.dart';
import '../widgets/photo_field.dart';

class EncomiendasScreen extends StatefulWidget {
  const EncomiendasScreen({super.key});
  @override
  State<EncomiendasScreen> createState() => _EncomiendasScreenState();
}

class _EncomiendasScreenState extends State<EncomiendasScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _soloPend = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final rows = await db.query('encomiendas',
        where: _soloPend ? "edificio=? AND estado='pendiente'" : 'edificio=?',
        whereArgs: [ed], orderBy: 'id DESC');
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  Future<void> _entregar(Map<String, dynamic> e) async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => EntregaEncomienda(encomienda: e)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Encomiendas'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: SegmentedButton<bool>(
              style: SegmentedButton.styleFrom(backgroundColor: Colors.white),
              segments: const [
                ButtonSegment(value: true, label: Text('Pendientes')),
                ButtonSegment(value: false, label: Text('Todas')),
              ],
              selected: {_soloPend},
              onSelectionChanged: (s) {
                setState(() => _soloPend = s.first);
                _load();
              },
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFFEF6C00),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Nueva'),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const EncomiendaForm()));
          _load();
        },
      ),
      body: _rows.isEmpty
          ? const Center(child: Text('Sin encomiendas'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length,
              itemBuilder: (_, i) {
                final e = _rows[i];
                final pend = e['estado'] == 'pendiente';
                final hora = DateFormat('dd/MM HH:mm').format(DateTime.parse(e['created_at'] as String));
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: (pend ? const Color(0xFFEF6C00) : AppColors.verde).withOpacity(.15),
                      child: Icon(pend ? Icons.inventory_2 : Icons.check_circle,
                          color: pend ? const Color(0xFFEF6C00) : AppColors.verde),
                    ),
                    title: Text('Depto ${e['depto']} · ${e['destinatario'] ?? ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${e['empresa'] ?? ''}\nRecibida: $hora'),
                    isThreeLine: true,
                    trailing: pend
                        ? FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: AppColors.verde, minimumSize: const Size(0, 40)),
                            onPressed: () => _entregar(e),
                            child: const Text('Entregar'))
                        : const Icon(Icons.done_all, color: Colors.grey),
                  ),
                );
              },
            ),
    );
  }
}

class EncomiendaForm extends StatefulWidget {
  const EncomiendaForm({super.key});
  @override
  State<EncomiendaForm> createState() => _EncomiendaFormState();
}

class _EncomiendaFormState extends State<EncomiendaForm> {
  final _depto = TextEditingController();
  final _dest = TextEditingController();
  final _empresa = TextEditingController();
  String? _foto;
  bool _saving = false;

  Future<void> _guardar() async {
    if (_foto == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('La foto del paquete es obligatoria'), backgroundColor: AppColors.rojo));
      return;
    }
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    final id = await db.insert('encomiendas', {
      'guardia_nombre': s.userNombre,
      'foto': _foto,
      'depto': _depto.text,
      'destinatario': _dest.text,
      'empresa': _empresa.text,
      'estado': 'pendiente',
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'encomiendas', '$id');
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nueva Encomienda')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PhotoField(label: 'Foto del paquete', obligatoria: true, onChanged: (v) => _foto = v),
          TextField(controller: _depto, decoration: const InputDecoration(labelText: 'Departamento')),
          const SizedBox(height: 12),
          TextField(controller: _dest, decoration: const InputDecoration(labelText: 'Persona destinataria')),
          const SizedBox(height: 12),
          TextField(controller: _empresa, decoration: const InputDecoration(labelText: 'Empresa / courier')),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _saving ? null : _guardar,
            icon: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.save),
            label: const Text('Registrar encomienda'),
          ),
        ],
      ),
    );
  }
}

class EntregaEncomienda extends StatefulWidget {
  final Map<String, dynamic> encomienda;
  const EntregaEncomienda({super.key, required this.encomienda});
  @override
  State<EntregaEncomienda> createState() => _EntregaEncomiendaState();
}

class _EntregaEncomiendaState extends State<EntregaEncomienda> {
  String? _foto;
  bool _saving = false;

  Future<void> _confirmar() async {
    if (_foto == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Tome la foto del residente recibiendo'), backgroundColor: AppColors.rojo));
      return;
    }
    setState(() => _saving = true);
    final db = await DB.instance.database;
    await db.update('encomiendas', {
      'estado': 'entregado',
      'foto_entrega': _foto,
      'hora_entrega': DateTime.now().toIso8601String(),
    }, where: 'id=?', whereArgs: [widget.encomienda['id']]);
    await Audit.log('ENTREGAR', 'encomiendas', '${widget.encomienda['id']}');
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.encomienda;
    return Scaffold(
      appBar: AppBar(title: const Text('Entregar Encomienda')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              title: Text('Depto ${e['depto']} · ${e['destinatario'] ?? ''}'),
              subtitle: Text(e['empresa']?.toString() ?? ''),
            ),
          ),
          const SizedBox(height: 12),
          PhotoField(label: 'Foto del residente recibiendo', obligatoria: true, onChanged: (v) => _foto = v),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.verde),
            onPressed: _saving ? null : _confirmar,
            icon: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.check),
            label: const Text('Confirmar entrega'),
          ),
        ],
      ),
    );
  }
}
