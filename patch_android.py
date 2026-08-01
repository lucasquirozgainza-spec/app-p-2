import 'dart:io';
import 'package:flutter/material.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/contact_launch.dart';
import '../theme.dart';
import '../widgets/photo_field.dart';

class VehiculosScreen extends StatefulWidget {
  const VehiculosScreen({super.key});
  @override
  State<VehiculosScreen> createState() => _VehiculosScreenState();
}

class _VehiculosScreenState extends State<VehiculosScreen> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final q = _q.text.trim();
    final rows = await db.query('vehiculos',
        where: q.isEmpty
            ? 'edificio=?'
            : 'edificio=? AND (placa LIKE ? OR vehiculo LIKE ? OR marca LIKE ? OR depto LIKE ? OR propietario LIKE ?)',
        whereArgs: q.isEmpty ? [ed] : [ed, '%$q%', '%$q%', '%$q%', '%$q%', '%$q%'],
        orderBy: 'placa');
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vehiculos')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF283593),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Registrar'),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const VehiculoForm()));
          _load();
        },
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _q,
              onChanged: (_) => _load(),
              decoration: const InputDecoration(
                  hintText: 'Buscar por placa, marca, depto...', prefixIcon: Icon(Icons.search)),
            ),
          ),
          Expanded(
            child: _rows.isEmpty
                ? const Center(child: Text('Sin vehiculos. Toca "Registrar".'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _rows.length,
                    itemBuilder: (_, i) {
                      final v = _rows[i];
                      final placa = (v['placa']?.toString() ?? '').trim();
                      final depto = (v['depto']?.toString() ?? '').trim();
                      final tel = (v['telefono']?.toString() ?? '').trim();
                      final foto = (v['foto']?.toString() ?? '');
                      final tieneFoto = foto.isNotEmpty && File(foto).existsSync();
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                              backgroundColor: const Color(0x1A283593),
                              backgroundImage: tieneFoto ? FileImage(File(foto)) : null,
                              child: tieneFoto ? null : const Icon(Icons.directions_car, color: Color(0xFF283593))),
                          title: Text(depto.isNotEmpty ? 'Depto $depto' : 'Sin depto',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text([
                            placa.isNotEmpty ? 'Placa $placa' : null,
                            v['vehiculo'], v['marca'], v['color'], v['propietario'],
                          ].where((e) => e != null && e.toString().trim().isNotEmpty).join(' · ')),
                          onTap: () async {
                            await Navigator.push(context,
                                MaterialPageRoute(builder: (_) => VehiculoDetalle(veh: v)));
                            _load();
                          },
                          trailing: tel.isEmpty
                              ? const Icon(Icons.edit, color: Colors.grey, size: 20)
                              : Row(mainAxisSize: MainAxisSize.min, children: [
                                  IconButton(
                                      icon: const Icon(Icons.call, color: AppColors.azulMarino),
                                      tooltip: 'Llamar',
                                      onPressed: () => Contacto.llamar(context, tel)),
                                  IconButton(
                                      icon: const Icon(Icons.chat, color: AppColors.verde),
                                      tooltip: 'WhatsApp (mal parqueado)',
                                      onPressed: () => Contacto.whatsapp(context, tel,
                                          mensaje: 'Estimado, su vehiculo${placa.isNotEmpty ? ' placa $placa' : ''} '
                                              'se encuentra mal estacionado. Por favor acercarse. (${AppState.instance.edificioNombre})')),
                                ]),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class VehiculoForm extends StatefulWidget {
  final Map<String, dynamic>? existente;
  const VehiculoForm({super.key, this.existente});
  @override
  State<VehiculoForm> createState() => _VehiculoFormState();
}

class _VehiculoFormState extends State<VehiculoForm> {
  final _placa = TextEditingController();
  final _marca = TextEditingController();
  final _modelo = TextEditingController();
  final _color = TextEditingController();
  final _depto = TextEditingController();
  final _prop = TextEditingController();
  final _parqueo = TextEditingController();
  final _tel = TextEditingController();
  final _obs = TextEditingController();
  String? _foto;
  bool _saving = false;

  bool get _editando => widget.existente != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existente;
    if (e != null) {
      _placa.text = e['placa']?.toString() ?? '';
      _marca.text = e['marca']?.toString() ?? '';
      _modelo.text = e['modelo']?.toString() ?? '';
      _color.text = e['color']?.toString() ?? '';
      _depto.text = e['depto']?.toString() ?? '';
      _prop.text = e['propietario']?.toString() ?? '';
      _parqueo.text = e['nro_parqueo']?.toString() ?? '';
      _tel.text = e['telefono']?.toString() ?? '';
      _obs.text = e['observaciones']?.toString() ?? '';
      _foto = e['foto']?.toString();
    }
  }

  Future<void> _guardar() async {
    if (_placa.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ingrese la placa'), backgroundColor: AppColors.rojo));
      return;
    }
    setState(() => _saving = true);
    final db = await DB.instance.database;
    final data = {
      'edificio': AppState.instance.edificioId,
      'placa': _placa.text.trim().toUpperCase(),
      'marca': _marca.text,
      'modelo': _modelo.text,
      'color': _color.text,
      'vehiculo': [_marca.text, _modelo.text].where((e) => e.isNotEmpty).join(' '),
      'depto': _depto.text,
      'propietario': _prop.text,
      'nro_parqueo': _parqueo.text,
      'telefono': _tel.text,
      'foto': _foto,
      'observaciones': _obs.text,
    };
    if (_editando) {
      await db.update('vehiculos', data, where: 'id=?', whereArgs: [widget.existente!['id']]);
      await Audit.log('EDITAR', 'vehiculos', '${widget.existente!['id']}', detalle: _placa.text);
    } else {
      final id = await db.insert('vehiculos', data);
      await Audit.log('CREAR', 'vehiculos', '$id', detalle: _placa.text);
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_editando ? 'Editar Vehiculo' : 'Registrar Vehiculo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _placa, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Placa *')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: _marca, decoration: const InputDecoration(labelText: 'Marca'))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _modelo, decoration: const InputDecoration(labelText: 'Modelo'))),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: _color, decoration: const InputDecoration(labelText: 'Color'))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _depto, decoration: const InputDecoration(labelText: 'Departamento'))),
          ]),
          const SizedBox(height: 12),
          TextField(controller: _prop, decoration: const InputDecoration(labelText: 'Dueño / responsable')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: _parqueo, decoration: const InputDecoration(labelText: 'Parqueo que ocupa'))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _tel, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Telefono'))),
          ]),
          const SizedBox(height: 16),
          PhotoField(label: 'Foto del vehiculo', initialPath: _foto, onChanged: (v) => _foto = v),
          TextField(controller: _obs, maxLines: 2, decoration: const InputDecoration(labelText: 'Observaciones')),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : _guardar,
            icon: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.save),
            label: const Text('Guardar vehiculo'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class VehiculoDetalle extends StatefulWidget {
  final Map<String, dynamic> veh;
  const VehiculoDetalle({super.key, required this.veh});
  @override
  State<VehiculoDetalle> createState() => _VehiculoDetalleState();
}

class _VehiculoDetalleState extends State<VehiculoDetalle> {
  late Map<String, dynamic> v;

  @override
  void initState() {
    super.initState();
    v = Map<String, dynamic>.from(widget.veh);
  }

  Future<void> _recargar() async {
    final db = await DB.instance.database;
    final rows = await db.query('vehiculos', where: 'id=?', whereArgs: [v['id']]);
    if (rows.isNotEmpty && mounted) setState(() => v = rows.first);
  }

  Widget _dato(String label, Object? value) {
    final val = value?.toString() ?? '';
    if (val.trim().isEmpty) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      title: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      subtitle: Text(val, style: const TextStyle(fontSize: 15, color: Colors.black87)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final foto = v['foto']?.toString() ?? '';
    final tieneFoto = foto.isNotEmpty && File(foto).existsSync();
    final tel = (v['telefono']?.toString() ?? '').trim();
    return Scaffold(
      appBar: AppBar(
        title: Text(v['depto']?.toString().isNotEmpty ?? false ? 'Depto ${v['depto']}' : 'Vehiculo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Editar',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => VehiculoForm(existente: v)));
              _recargar();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (tieneFoto)
            GestureDetector(
              onTap: () => showDialog(context: context, builder: (_) => Dialog(child: InteractiveViewer(child: Image.file(File(foto))))),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(File(foto), height: 220, width: double.infinity, fit: BoxFit.cover, cacheWidth: 900),
              ),
            )
          else
            Container(
              height: 160,
              decoration: BoxDecoration(color: const Color(0x1A283593), borderRadius: BorderRadius.circular(12)),
              child: const Center(child: Icon(Icons.directions_car, size: 60, color: Color(0xFF283593))),
            ),
          const SizedBox(height: 12),
          Card(child: Column(children: [
            _dato('Departamento', v['depto']),
            _dato('Placa', v['placa']),
            _dato('Vehiculo', v['vehiculo']),
            _dato('Marca', v['marca']),
            _dato('Modelo', v['modelo']),
            _dato('Color', v['color']),
            _dato('Dueño / responsable', v['propietario']),
            _dato('Nro parqueo', v['nro_parqueo']),
            _dato('Telefono', v['telefono']),
            _dato('Observaciones', v['observaciones']),
          ])),
          if (tel.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: AppColors.verde),
                onPressed: () => Contacto.whatsapp(context, tel,
                    mensaje: 'Estimado, su vehiculo placa ${v['placa'] ?? ''} se encuentra mal estacionado. '
                        'Por favor acercarse. (${AppState.instance.edificioNombre})'),
                icon: const Icon(Icons.chat),
                label: const Text('Avisar por WhatsApp'),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Contacto.llamar(context, tel),
                icon: const Icon(Icons.call),
                label: const Text('Llamar'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
