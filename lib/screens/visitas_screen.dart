import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/device_context.dart';
import '../theme.dart';
import '../widgets/photo_field.dart';
import '../widgets/common.dart';

class VisitasScreen extends StatefulWidget {
  const VisitasScreen({super.key});
  @override
  State<VisitasScreen> createState() => _VisitasScreenState();
}

class _VisitasScreenState extends State<VisitasScreen> {
  List<Map<String, dynamic>> _visitas = [];
  bool _soloDentro = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final rows = await db.query('visitas',
        where: _soloDentro ? 'edificio=? AND estado=?' : 'edificio=?',
        whereArgs: _soloDentro ? [ed, 'dentro'] : [ed],
        orderBy: 'id DESC');
    if (!mounted) return;
    setState(() => _visitas = rows);
  }

  Future<void> _registrarSalida(Map<String, dynamic> v) async {
    final db = await DB.instance.database;
    await db.update('visitas',
        {'estado': 'salio', 'hora_salida': DateTime.now().toIso8601String()},
        where: 'id=?', whereArgs: [v['id']]);
    await Audit.log('SALIDA_VISITA', 'visitas', '${v['id']}');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Visitas'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: SegmentedButton<bool>(
              style: SegmentedButton.styleFrom(
                  backgroundColor: Colors.white, selectedBackgroundColor: Colors.white),
              segments: const [
                ButtonSegment(value: true, label: Text('Dentro'), icon: Icon(Icons.login)),
                ButtonSegment(value: false, label: Text('Todas'), icon: Icon(Icons.list)),
              ],
              selected: {_soloDentro},
              onSelectionChanged: (s) {
                setState(() => _soloDentro = s.first);
                _load();
              },
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.azulMarino,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Nueva visita'),
        onPressed: () async {
          await Navigator.push(context,
              MaterialPageRoute(builder: (_) => const VisitaFormScreen()));
          _load();
        },
      ),
      body: _visitas.isEmpty
          ? const Center(child: Text('Sin visitas registradas'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _visitas.length,
              itemBuilder: (_, i) {
                final v = _visitas[i];
                final dentro = v['estado'] == 'dentro';
                final hora = DateFormat('dd/MM HH:mm')
                    .format(DateTime.parse(v['created_at'] as String));
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: dentro
                          ? AppColors.verde.withOpacity(.15)
                          : Colors.grey.shade200,
                      backgroundImage: (v['foto_visitante'] != null &&
                              File(v['foto_visitante'] as String).existsSync())
                          ? FileImage(File(v['foto_visitante'] as String))
                          : null,
                      child: (v['foto_visitante'] == null)
                          ? Icon(Icons.person,
                              color: dentro ? AppColors.verde : Colors.grey)
                          : null,
                    ),
                    title: Text(v['nombre_visita']?.toString() ?? '—',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        'Depto ${v['depto'] ?? '-'} · ${v['motivo'] ?? ''}\nIngreso: $hora'),
                    isThreeLine: true,
                    trailing: dentro
                        ? TextButton(
                            onPressed: () => _registrarSalida(v),
                            child: const Text('Salida',
                                style: TextStyle(color: AppColors.rojo)))
                        : const Icon(Icons.check_circle, color: Colors.grey),
                  ),
                );
              },
            ),
    );
  }
}

// ---------------------------------------------------------------------------

class VisitaFormScreen extends StatefulWidget {
  const VisitaFormScreen({super.key});
  @override
  State<VisitaFormScreen> createState() => _VisitaFormScreenState();
}

class _VisitaFormScreenState extends State<VisitaFormScreen> {
  final _nombre = TextEditingController();
  final _ci = TextEditingController();
  final _depto = TextEditingController();
  final _autoriza = TextEditingController();
  final _motivo = TextEditingController();
  final _cantidad = TextEditingController(text: '1');
  final _placa = TextEditingController();
  final _obs = TextEditingController();
  String? _fotoCi;
  String? _fotoVisita;
  String? _fotoTarjeta;
  bool _saving = false;
  final _ahora = DateTime.now();

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: AppColors.rojo));

  Future<void> _guardar() async {
    if (_nombre.text.trim().isEmpty) return _snack('Ingrese el nombre');
    if (_fotoCi == null) return _snack('La foto del CI es obligatoria');
    if (_fotoVisita == null) return _snack('La foto del visitante es obligatoria');
    setState(() => _saving = true);
    final s = AppState.instance;
    final gps = await DeviceContext.gps();
    final disp = await DeviceContext.dispositivo();
    final db = await DB.instance.database;
    final id = await db.insert('visitas', {
      'guardia_id': s.userId,
      'guardia_nombre': s.userNombre,
      'tarjeta': _fotoTarjeta,
      'nombre_visita': _nombre.text.trim(),
      'ci': _ci.text,
      'foto_ci': _fotoCi,
      'foto_visitante': _fotoVisita,
      'depto': _depto.text,
      'autoriza': _autoriza.text,
      'motivo': _motivo.text,
      'cantidad': int.tryParse(_cantidad.text) ?? 1,
      'placa': _placa.text,
      'gps_lat': gps?['lat'],
      'gps_lng': gps?['lng'],
      'dispositivo': disp,
      'observaciones': _obs.text,
      'estado': 'dentro',
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'visitas', '$id', detalle: _nombre.text);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Registrar Visita')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _nombre, decoration: const InputDecoration(labelText: 'Nombre completo *')),
          const SizedBox(height: 12),
          TextField(controller: _ci, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'CI')),
          const SizedBox(height: 16),
          PhotoField(label: 'Foto del CI', obligatoria: true, onChanged: (v) => _fotoCi = v),
          PhotoField(label: 'Foto del visitante', obligatoria: true, onChanged: (v) => _fotoVisita = v),
          TextField(controller: _depto, decoration: const InputDecoration(labelText: 'Departamento')),
          const SizedBox(height: 12),
          TextField(controller: _autoriza, decoration: const InputDecoration(labelText: 'Persona que autoriza')),
          const SizedBox(height: 12),
          TextField(controller: _motivo, decoration: const InputDecoration(labelText: 'Motivo')),
          const SizedBox(height: 12),
          TextField(controller: _cantidad, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Cantidad de personas')),
          const SizedBox(height: 12),
          TextField(controller: _placa, decoration: const InputDecoration(labelText: 'Placa vehiculo')),
          const SizedBox(height: 16),
          PhotoField(label: 'Foto de la tarjeta asignada', onChanged: (v) => _fotoTarjeta = v),
          TextField(controller: _obs, maxLines: 2, decoration: const InputDecoration(labelText: 'Observaciones')),
          const SizedBox(height: 16),
          LockedField(label: 'Guardia', value: s.userNombre ?? '', icon: Icons.shield),
          Row(children: [
            Expanded(child: LockedField(label: 'Fecha', value: DateFormat('dd/MM/yyyy').format(_ahora), icon: Icons.calendar_today)),
            const SizedBox(width: 10),
            Expanded(child: LockedField(label: 'Hora ingreso', value: DateFormat('HH:mm').format(_ahora), icon: Icons.access_time)),
          ]),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _saving ? null : _guardar,
            icon: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.save),
            label: const Text('Registrar ingreso'),
          ),
        ],
      ),
    );
  }
}
