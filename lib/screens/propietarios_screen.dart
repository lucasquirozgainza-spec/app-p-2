import 'package:flutter/material.dart';
import '../services/sync_remoto.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/contact_launch.dart';
import '../services/contactos_repo.dart';
import '../theme.dart';
import '../widgets/toast.dart';

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
  void dispose() {
    _q.dispose();
    super.dispose();
  }

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
      bottomNavigationBar: widget.soloVehiculos
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                child: Row(children: [
                  for (final t in const ['propietario', 'inquilino', 'residente']) ...[
                    if (t != 'propietario') const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: t == 'propietario'
                              ? const Color(0xFF1565C0)
                              : t == 'inquilino'
                                  ? const Color(0xFF00897B)
                                  : const Color(0xFF6D4C41),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: Icon(t == 'residente' ? Icons.family_restroom : Icons.person_add, size: 18),
                        label: Text(t == 'propietario' ? 'Propietario' : t == 'inquilino' ? 'Inquilino' : 'Residente',
                            style: const TextStyle(fontSize: 13)),
                        onPressed: () async {
                          await Navigator.push(context, MaterialPageRoute(builder: (_) => PersonaForm(tipo: t)));
                          _load();
                        },
                      ),
                    ),
                  ],
                ]),
              ),
            ),
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
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
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
        title: Text((p['copropietario']?.toString() ?? '').isNotEmpty ? p['copropietario'].toString() : 'Sin propietario',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('Depto ${p['depto']}$torre'
            '${(p['inquilino']?.toString() ?? '').isNotEmpty ? '  ·  Inquilino: ${p['inquilino']}' : ''}'),
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
  List<Map<String, dynamic>> _vehiculos = [];

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
    final veh = await db.query('vehiculos',
        where: 'edificio=? AND depto=?', whereArgs: [p['edificio'], p['depto']], orderBy: 'nro_parqueo');
    if (!mounted) return;
    setState(() {
      _residentes = rows;
      _vehiculos = veh;
    });
  }

  Future<void> _agregarResidente() async {
    final n = TextEditingController();
    final par = TextEditingController();
    final cel = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Agregar residente - Depto ${p['depto']}'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: n, decoration: const InputDecoration(labelText: 'Nombre')),
            const SizedBox(height: 8),
            TextField(controller: par, decoration: const InputDecoration(labelText: 'Parentesco')),
            const SizedBox(height: 8),
            TextField(controller: cel, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Celular')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Agregar')),
        ],
      ),
    );
    if (ok == true && n.text.trim().isNotEmpty) {
      final db = await DB.instance.database;
      final id = await db.insert('residentes', {
        'edificio': p['edificio'], 'depto': p['depto'], 'nombre': n.text.trim(),
        'parentesco': par.text, 'celular': cel.text,
      });
      await Audit.log('CREAR', 'residentes', '$id', detalle: 'depto ${p['depto']}');
      SyncRemoto.publicarDatos('residentes');
      _loadResidentes();
    }
  }

  static const _etiquetas = {
    'copropietario': 'Propietario',
    'telefono': 'Teléfono propietario',
    'inquilino': 'Inquilino',
    'telefono_inq': 'Teléfono inquilino',
    'mascota': 'Mascota',
    'observaciones': 'Observaciones',
  };

  Future<void> _editar() async {
    final ctrls = {
      'copropietario': TextEditingController(text: p['copropietario']?.toString()),
      'telefono': TextEditingController(text: p['telefono']?.toString()),
      'inquilino': TextEditingController(text: p['inquilino']?.toString()),
      'telefono_inq': TextEditingController(text: p['telefono_inq']?.toString()),
      'mascota': TextEditingController(text: p['mascota']?.toString()),
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
                    decoration: InputDecoration(labelText: _etiquetas[e.key] ?? e.key, isDense: true),
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
      SyncRemoto.publicarDatos('propietarios');
      if (!mounted) return;
      setState(() => p.addAll(data));
      widget.onChanged();
    }
  }

  Future<void> _marcarEncargado(String nombre, String tel) async {
    await ContactosRepo.setEncargado(p['depto']?.toString() ?? '', nombre, tel);
    if (mounted) TopToast.show(context, '$nombre es el encargado del depto ${p['depto']}');
  }

  Widget _row(String label, String? value, {String? tel}) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      title: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      subtitle: Text(value, style: const TextStyle(fontSize: 15, color: Colors.black87)),
      trailing: (tel != null && tel.isNotEmpty)
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.star_border, color: Color(0xFFEF6C00)), tooltip: 'Marcar como encargado', onPressed: () => _marcarEncargado(value, tel)),
              IconButton(icon: const Icon(Icons.call, color: AppColors.azulMarino), tooltip: 'Llamar', onPressed: () => Contacto.llamar(context, tel)),
              IconButton(icon: const Icon(Icons.chat, color: AppColors.verde), tooltip: 'WhatsApp', onPressed: () => Contacto.whatsapp(context, tel)),
            ])
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Depto ${p['depto']}'),
        actions: [
          IconButton(icon: const Icon(Icons.edit), tooltip: 'Editar', onPressed: _editar),
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
                _row('Mascota', p['mascota']?.toString()),
                _row('Nombre mascota', p['nombre_mascota']?.toString()),
                _row('Observaciones', p['observaciones']?.toString()),
              ],
            ),
          ),
          if (_vehiculos.isNotEmpty || (p['placa']?.toString() ?? '').isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 12, 8, 4),
              child: Text('Vehículos', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            Card(
              child: Column(children: [
                for (final v in _vehiculos)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.directions_car, color: Color(0xFF283593)),
                    title: Text('${v['placa'] ?? ''}${(v['nro_parqueo']?.toString() ?? '').isNotEmpty ? '  ·  Parqueo ${v['nro_parqueo']}' : ''}'),
                    subtitle: Text([v['vehiculo'], v['color'], v['propietario']]
                        .where((e) => e != null && e.toString().trim().isNotEmpty)
                        .join(' · ')),
                  ),
                // registro antiguo (la placa se cargaba en el propietario)
                if (_vehiculos.isEmpty)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.directions_car, color: Color(0xFF283593)),
                    title: Text('${p['placa'] ?? ''}${(p['nro_parqueo']?.toString() ?? '').isNotEmpty ? '  ·  Parqueo ${p['nro_parqueo']}' : ''}'),
                    subtitle: (p['vehiculo']?.toString() ?? '').isNotEmpty ? Text(p['vehiculo'].toString()) : null,
                  ),
              ]),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Residentes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              TextButton.icon(
                onPressed: _agregarResidente,
                icon: const Icon(Icons.person_add, size: 18),
                label: const Text('Agregar'),
              ),
            ],
          ),
          if (_residentes.isEmpty)
            const Card(child: ListTile(title: Text('Sin residentes registrados')))
          else
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
                          ? Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(icon: const Icon(Icons.star_border, color: Color(0xFFEF6C00)), tooltip: 'Encargado', onPressed: () => _marcarEncargado(r['nombre']?.toString() ?? '', r['celular'].toString())),
                              IconButton(icon: const Icon(Icons.call, color: AppColors.azulMarino), onPressed: () => Contacto.llamar(context, r['celular'].toString())),
                              IconButton(icon: const Icon(Icons.chat, color: AppColors.verde), onPressed: () => Contacto.whatsapp(context, r['celular'].toString())),
                            ])
                          : null,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Registro rápido por departamento: PROPIETARIO, INQUILINO o RESIDENTE.
/// Los vehículos se registran en "Vehículos" (con su parqueo).
class PersonaForm extends StatefulWidget {
  final String tipo; // propietario | inquilino | residente
  const PersonaForm({super.key, required this.tipo});
  @override
  State<PersonaForm> createState() => _PersonaFormState();
}

class _PersonaFormState extends State<PersonaForm> {
  final _depto = TextEditingController();
  final _nombre = TextEditingController();
  final _tel = TextEditingController();
  final _parentesco = TextEditingController();
  final _obs = TextEditingController();
  String _torre = '';
  bool _saving = false;

  String get _titulo => widget.tipo == 'propietario'
      ? 'Registrar propietario'
      : widget.tipo == 'inquilino'
          ? 'Registrar inquilino'
          : 'Registrar residente';

  @override
  void dispose() {
    for (final c in [_depto, _nombre, _tel, _parentesco, _obs]) {
      c.dispose();
    }
    super.dispose();
  }

  void _aviso(String t) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(t), backgroundColor: AppColors.rojo));

  Future<void> _guardar() async {
    final depto = _depto.text.trim();
    final nombre = _nombre.text.trim();
    if (depto.isEmpty) {
      _aviso('Escribe el departamento');
      return;
    }
    if (nombre.isEmpty) {
      _aviso('Escribe el nombre');
      return;
    }
    setState(() => _saving = true);
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    if (widget.tipo == 'residente') {
      final id = await db.insert('residentes', {
        'edificio': ed, 'depto': depto, 'nombre': nombre,
        'parentesco': _parentesco.text.trim(), 'celular': _tel.text.trim(), 'observaciones': _obs.text.trim(),
      });
      await Audit.log('CREAR', 'residentes', '$id', detalle: 'depto $depto');
      SyncRemoto.publicarDatos('residentes');
    } else {
      // Un registro por departamento: si ya existe, se completa (propietario o inquilino).
      final previos = await db.query('propietarios',
          where: _torre.isEmpty ? 'edificio=? AND depto=?' : 'edificio=? AND depto=? AND torre=?',
          whereArgs: _torre.isEmpty ? [ed, depto] : [ed, depto, _torre], limit: 1);
      final datos = widget.tipo == 'propietario'
          ? {'copropietario': nombre, 'telefono': _tel.text.trim()}
          : {'inquilino': nombre, 'telefono_inq': _tel.text.trim()};
      if (_obs.text.trim().isNotEmpty) datos['observaciones'] = _obs.text.trim();
      if (previos.isNotEmpty) {
        await db.update('propietarios', datos, where: 'id=?', whereArgs: [previos.first['id']]);
        await Audit.log('EDITAR', 'propietarios', '${previos.first['id']}', detalle: '${widget.tipo} depto $depto');
      } else {
        final id = '$ed-$depto-${DateTime.now().millisecondsSinceEpoch}';
        await db.insert('propietarios', {'id': id, 'edificio': ed, 'torre': _torre, 'depto': depto, ...datos});
        await Audit.log('CREAR', 'propietarios', id, detalle: '${widget.tipo} depto $depto');
      }
      SyncRemoto.publicarDatos('propietarios');
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final torres = AppState.instance.torres;
    final residente = widget.tipo == 'residente';
    return Scaffold(
      appBar: AppBar(title: Text(_titulo)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _depto, decoration: const InputDecoration(labelText: 'Departamento *')),
          if (torres.length > 1) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              for (final t in torres)
                ChoiceChip(label: Text(t), selected: _torre == t, onSelected: (v) => setState(() => _torre = v ? t : '')),
            ]),
          ],
          const SizedBox(height: 12),
          TextField(controller: _nombre, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Nombre *')),
          const SizedBox(height: 12),
          TextField(controller: _tel, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Celular')),
          if (residente) ...[
            const SizedBox(height: 12),
            TextField(controller: _parentesco, decoration: const InputDecoration(labelText: 'Parentesco (hijo, esposa…)')),
          ],
          const SizedBox(height: 12),
          TextField(controller: _obs, maxLines: 2, decoration: const InputDecoration(labelText: 'Observaciones')),
          const SizedBox(height: 16),
          FilledButton.icon(
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
