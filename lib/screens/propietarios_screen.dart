import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../theme.dart';

class PropietariosScreen extends StatefulWidget {
  final bool soloVehiculos;
  const PropietariosScreen({super.key, this.soloVehiculos = false});
  @override
  State<PropietariosScreen> createState() => _PropietariosScreenState();
}

class _PropietariosScreenState extends State<PropietariosScreen> {
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
    if (widget.soloVehiculos) {
      final rows = await db.query('propietarios',
          where: q.isEmpty
              ? "edificio=? AND (placa!='' OR vehiculo!='')"
              : "edificio=? AND (placa!='' OR vehiculo!='') AND (placa LIKE ? OR vehiculo LIKE ? OR depto LIKE ? OR copropietario LIKE ?)",
          whereArgs: q.isEmpty ? [ed] : [ed, '%$q%', '%$q%', '%$q%', '%$q%'],
          orderBy: 'depto');
      if (!mounted) return;
      setState(() => _rows = rows);
      return;
    }
    final rows = await db.query('propietarios',
        where: q.isEmpty
            ? 'edificio=?'
            : 'edificio=? AND (depto LIKE ? OR copropietario LIKE ? OR inquilino LIKE ? OR placa LIKE ?)',
        whereArgs: q.isEmpty ? [ed] : [ed, '%$q%', '%$q%', '%$q%', '%$q%'],
        orderBy: 'depto');
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.soloVehiculos ? 'Vehiculos' : 'Propietarios')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _q,
              onChanged: (_) => _load(),
              decoration: InputDecoration(
                hintText: widget.soloVehiculos
                    ? 'Buscar por placa, vehiculo, depto...'
                    : 'Buscar por depto, nombre, placa...',
                prefixIcon: const Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: _rows.isEmpty
                ? const Center(child: Text('Sin resultados'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _rows.length,
                    itemBuilder: (_, i) => widget.soloVehiculos
                        ? _vehiculoTile(_rows[i])
                        : _propTile(_rows[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _propTile(Map<String, dynamic> p) {
    final torre = (p['torre']?.toString() ?? '').isEmpty ? '' : ' · Torre ${p['torre']}';
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppColors.azulMarino.withOpacity(.1),
          child: Text(p['depto']?.toString() ?? '?',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.azulMarino)),
        ),
        title: Text(p['copropietario']?.toString() ?? '—',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('Depto ${p['depto']}$torre'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => PropietarioDetalle(prop: p, onChanged: _load))),
      ),
    );
  }

  Widget _vehiculoTile(Map<String, dynamic> p) {
    return Card(
      child: ListTile(
        leading: const CircleAvatar(
            backgroundColor: Color(0x1A0A335D),
            child: Icon(Icons.directions_car, color: AppColors.azulMarino)),
        title: Text(
            (p['placa']?.toString().isNotEmpty ?? false) ? p['placa'].toString() : (p['vehiculo']?.toString() ?? '—'),
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${p['vehiculo'] ?? ''}  ·  Depto ${p['depto']}  ·  ${p['copropietario'] ?? ''}'),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class PropietarioDetalle extends StatefulWidget {
  final Map<String, dynamic> prop;
  final VoidCallback onChanged;
  const PropietarioDetalle({super.key, required this.prop, required this.onChanged});
  @override
  State<PropietarioDetalle> createState() => _PropietarioDetalleState();
}

class _PropietarioDetalleState extends State<PropietarioDetalle> {
  late Map<String, dynamic> p;
  List<Map<String, dynamic>> _residentes = [];

  @override
  void initState() {
    super.initState();
    p = Map<String, dynamic>.from(widget.prop);
    _loadResidentes();
  }

  Future<void> _loadResidentes() async {
    final db = await DB.instance.database;
    final rows = await db.query('residentes',
        where: 'edificio=? AND depto=?', whereArgs: [p['edificio'], p['depto']]);
    if (!mounted) return;
    setState(() => _residentes = rows);
  }

  Future<void> _llamar(String tel) async {
    final uri = Uri.parse('tel:$tel');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _editar() async {
    final ctrls = {
      'copropietario': TextEditingController(text: p['copropietario']?.toString()),
      'telefono': TextEditingController(text: p['telefono']?.toString()),
      'inquilino': TextEditingController(text: p['inquilino']?.toString()),
      'telefono_inq': TextEditingController(text: p['telefono_inq']?.toString()),
      'vehiculo': TextEditingController(text: p['vehiculo']?.toString()),
      'placa': TextEditingController(text: p['placa']?.toString()),
      'nro_parqueo': TextEditingController(text: p['nro_parqueo']?.toString()),
      'observaciones': TextEditingController(text: p['observaciones']?.toString()),
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Editar Depto ${p['depto']}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in ctrls.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: e.value,
                    decoration: InputDecoration(labelText: e.key, isDense: true),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok == true) {
      final db = await DB.instance.database;
      final data = {for (final e in ctrls.entries) e.key: e.value.text};
      await db.update('propietarios', data, where: 'id=?', whereArgs: [p['id']]);
      await Audit.log('EDITAR', 'propietarios', p['id'].toString());
      setState(() => p.addAll(data));
      widget.onChanged();
    }
  }

  Widget _row(String label, String? value, {String? tel}) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      title: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      subtitle: Text(value, style: const TextStyle(fontSize: 15, color: Colors.black87)),
      trailing: tel != null && tel.isNotEmpty
          ? IconButton(icon: const Icon(Icons.call, color: AppColors.verde), onPressed: () => _llamar(tel))
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Depto ${p['depto']}'),
        actions: [
          if (AppState.instance.isAdmin)
            IconButton(icon: const Icon(Icons.edit), onPressed: _editar),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Column(
              children: [
                _row('Copropietario', p['copropietario']?.toString(), tel: p['telefono']?.toString()),
                _row('Telefono', p['telefono']?.toString()),
                _row('Inquilino', p['inquilino']?.toString(), tel: p['telefono_inq']?.toString()),
                _row('Nro Parqueo', p['nro_parqueo']?.toString()),
                _row('Vehiculo', p['vehiculo']?.toString()),
                _row('Placa', p['placa']?.toString()),
                _row('Mascota', p['mascota']?.toString()),
                _row('Nombre mascota', p['nombre_mascota']?.toString()),
                _row('Observaciones', p['observaciones']?.toString()),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (_residentes.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('Residentes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            Card(
              child: Column(
                children: [
                  for (final r in _residentes)
                    ListTile(
                      leading: const Icon(Icons.person_outline, color: AppColors.azulMarino),
                      title: Text(r['nombre']?.toString() ?? ''),
                      subtitle: (r['parentesco']?.toString().isNotEmpty ?? false)
                          ? Text(r['parentesco'].toString())
                          : null,
                      trailing: (r['celular']?.toString().isNotEmpty ?? false)
                          ? IconButton(icon: const Icon(Icons.call, color: AppColors.verde), onPressed: () => _llamar(r['celular'].toString()))
                          : null,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
