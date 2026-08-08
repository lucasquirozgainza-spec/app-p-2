import 'dart:io';
import 'package:flutter/material.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/ocr_service.dart';
import '../theme.dart';
import '../widgets/depto_field.dart';
import '../widgets/toast.dart';
import 'camera_screen.dart';

const _colorRecu = Color(0xFF00695C);

/// Visitas recurrentes. Nivel 1 (deptoFiltro == null): tarjetas por
/// departamento. Nivel 2 (deptoFiltro != null): las personas de ese depto, con
/// un solo botón para marcar ingreso o salida.
class RecurrentesScreen extends StatefulWidget {
  final String? deptoFiltro; // null = ver por departamentos
  const RecurrentesScreen({super.key, this.deptoFiltro});
  @override
  State<RecurrentesScreen> createState() => _RecurrentesScreenState();
}

class _RecurrentesScreenState extends State<RecurrentesScreen> {
  List<Map<String, dynamic>> _rows = [];
  final _buscar = TextEditingController();

  bool get _porDepto => widget.deptoFiltro == null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _buscar.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final rows = await db.query('recurrentes',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'nombre');
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  String _depto(Map<String, dynamic> r) {
    final d = (r['depto'] ?? '').toString().trim();
    return d.isEmpty ? 'Sin depto' : d;
  }

  /// Marca ingreso o salida. [deptoOverride] permite, por excepción, enviar la
  /// visita a otro depto sin cambiar el depto habitual del recurrente.
  Future<void> _marcar(Map<String, dynamic> r, {String? deptoOverride}) async {
    final db = await DB.instance.database;
    final s = AppState.instance;
    final dentro = (r['dentro'] ?? 0) == 1;
    if (!dentro) {
      final depto = (deptoOverride ?? r['depto'] ?? '').toString().trim();
      final vid = await db.insert('visitas', {
        'guardia_id': s.userId,
        'guardia_nombre': s.userNombre,
        'nombre_visita': r['nombre'],
        'ci': r['ci'],
        'foto_ci': r['foto'],
        'depto': depto,
        'motivo': r['motivo'],
        'placa': r['placa'],
        'observaciones': 'Visita recurrente',
        'estado': 'dentro',
        'edificio': s.edificioId,
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.update('recurrentes', {'dentro': 1, 'visita_abierta': vid},
          where: 'id=?', whereArgs: [r['id']]);
      Cloud.evento('Visita', detalle: {
        'nombre': r['nombre'], 'depto': depto, 'motivo': r['motivo'], 'tipo': 'recurrente ingreso',
      });
      if (mounted) TopToast.show(context, 'Ingreso de ${r['nombre']}${deptoOverride != null ? ' a depto $depto' : ''}');
    } else {
      final vid = r['visita_abierta'];
      if (vid != null) {
        await db.update('visitas',
            {'estado': 'salio', 'hora_salida': DateTime.now().toIso8601String()},
            where: 'id=?', whereArgs: [vid]);
      }
      await db.update('recurrentes', {'dentro': 0, 'visita_abierta': null},
          where: 'id=?', whereArgs: [r['id']]);
      Cloud.evento('Visita', detalle: {'nombre': r['nombre'], 'depto': r['depto'], 'tipo': 'recurrente salida'});
      if (mounted) TopToast.show(context, 'Salida de ${r['nombre']}');
    }
    await Audit.log('RECURRENTE', 'recurrentes', '${r['id']}', detalle: dentro ? 'salida' : 'ingreso');
    _load();
  }

  /// Ingreso a OTRO depto (caso excepcional).
  Future<void> _ingresoOtroDepto(Map<String, dynamic> r) async {
    final ctrl = TextEditingController(text: (r['depto'] ?? '').toString());
    final depto = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Ingreso de ${r['nombre']}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('¿A qué departamento ingresa esta vez?'),
          const SizedBox(height: 10),
          TextField(controller: ctrl, autofocus: true,
              decoration: const InputDecoration(labelText: 'Departamento', prefixIcon: Icon(Icons.meeting_room))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.verde),
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Marcar ingreso'),
          ),
        ],
      ),
    );
    if (depto != null && depto.isNotEmpty) _marcar(r, deptoOverride: depto);
  }

  Future<void> _eliminar(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('¿Eliminar a ${r['nombre']}?'),
        content: const Text('Se quita de la lista de recurrentes. El historial de visitas no se toca.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final db = await DB.instance.database;
    await db.delete('recurrentes', where: 'id=?', whereArgs: [r['id']]);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_porDepto ? 'Visitas recurrentes' : 'Depto ${widget.deptoFiltro}')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _colorRecu,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add),
        label: const Text('Registrar'),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(
              builder: (_) => RecurrenteForm(deptoInicial: _porDepto ? null : widget.deptoFiltro)));
          _load();
        },
      ),
      body: _porDepto ? _vistaDepartamentos() : _vistaPersonas(widget.deptoFiltro!),
    );
  }

  // --- Nivel 1: tarjetas por departamento -----------------------------------
  Widget _vistaDepartamentos() {
    final q = _buscar.text.trim().toLowerCase();
    final grupos = <String, List<Map<String, dynamic>>>{};
    for (final r in _rows) {
      if (q.isNotEmpty && !'${r['nombre']} ${r['depto']} ${r['ci']}'.toLowerCase().contains(q)) continue;
      grupos.putIfAbsent(_depto(r), () => []).add(r);
    }
    final deptos = grupos.keys.toList()..sort();
    return Column(children: [
      _buscador('Buscar por depto, nombre o CI'),
      Expanded(
        child: deptos.isEmpty
            ? const Center(child: Padding(padding: EdgeInsets.all(24),
                child: Text('Aún no hay visitas recurrentes.\nToca "Registrar" para agregar una.', textAlign: TextAlign.center)))
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final d in deptos)
                    Card(
                      child: ListTile(
                        leading: const CircleAvatar(backgroundColor: Color(0x1A00695C),
                            child: Icon(Icons.meeting_room, color: _colorRecu)),
                        title: Text('Depto $d', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        subtitle: Text('${grupos[d]!.length} persona(s)'
                            '${grupos[d]!.where((x) => (x['dentro'] ?? 0) == 1).isNotEmpty ? ' · ${grupos[d]!.where((x) => (x['dentro'] ?? 0) == 1).length} dentro' : ''}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final depto = d == 'Sin depto' ? '' : d;
                          await Navigator.push(context, MaterialPageRoute(
                              builder: (_) => RecurrentesScreen(deptoFiltro: depto)));
                          _load();
                        },
                      ),
                    ),
                ],
              ),
      ),
    ]);
  }

  // --- Nivel 2: personas de un depto ----------------------------------------
  Widget _vistaPersonas(String depto) {
    final gente = _rows.where((r) {
      final d = (r['depto'] ?? '').toString().trim();
      return depto.isEmpty ? d.isEmpty : d == depto;
    }).toList();
    return Column(children: [
      Expanded(
        child: gente.isEmpty
            ? const Center(child: Text('Sin personas en este depto'))
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: gente.length,
                itemBuilder: (_, i) => _tarjetaPersona(gente[i]),
              ),
      ),
    ]);
  }

  Widget _tarjetaPersona(Map<String, dynamic> r) {
    final dentro = (r['dentro'] ?? 0) == 1;
    final foto = (r['foto'] ?? '').toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            (foto.isNotEmpty && File(foto).existsSync())
                ? CircleAvatar(backgroundImage: FileImage(File(foto)))
                : CircleAvatar(backgroundColor: (dentro ? AppColors.verde : Colors.grey).withOpacity(.15),
                    child: Icon(Icons.person, color: dentro ? AppColors.verde : Colors.grey)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r['nombre']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                if ((r['motivo'] ?? '').toString().isNotEmpty)
                  Text(r['motivo'].toString(), style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: (dentro ? AppColors.verde : Colors.grey).withOpacity(.15), borderRadius: BorderRadius.circular(8)),
              child: Text(dentro ? 'DENTRO' : 'FUERA',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: dentro ? AppColors.verde : Colors.grey)),
            ),
            IconButton(icon: const Icon(Icons.delete_outline, color: Colors.black38, size: 20), onPressed: () => _eliminar(r)),
          ]),
          const SizedBox(height: 8),
          if (dentro)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: AppColors.rojo, minimumSize: const Size.fromHeight(46)),
                onPressed: () => _marcar(r),
                icon: const Icon(Icons.logout),
                label: const Text('Marcar SALIDA'),
              ),
            )
          else
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.verde, minimumSize: const Size.fromHeight(46)),
                  onPressed: () => _marcar(r),
                  icon: const Icon(Icons.login),
                  label: const Text('Marcar INGRESO'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _ingresoOtroDepto(r),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46), padding: const EdgeInsets.symmetric(horizontal: 12)),
                child: const Text('Otro depto'),
              ),
            ]),
        ]),
      ),
    );
  }

  Widget _buscador(String hint) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: TextField(
          controller: _buscar,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      );
}

/// Registra una persona recurrente UNA sola vez (con foto del carnet).
class RecurrenteForm extends StatefulWidget {
  final String? deptoInicial;
  const RecurrenteForm({super.key, this.deptoInicial});
  @override
  State<RecurrenteForm> createState() => _RecurrenteFormState();
}

class _RecurrenteFormState extends State<RecurrenteForm> {
  final _nombre = TextEditingController();
  final _ci = TextEditingController();
  late final _depto = TextEditingController(text: widget.deptoInicial ?? '');
  final _motivo = TextEditingController();
  final _placa = TextEditingController();
  List<String> _fotosCarnet = [];
  bool _leyendo = false;
  bool _saving = false;

  @override
  void dispose() {
    _nombre.dispose();
    _ci.dispose();
    _depto.dispose();
    _motivo.dispose();
    _placa.dispose();
    super.dispose();
  }

  Future<void> _fotoCarnet() async {
    final res = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(builder: (_) => const CameraScreen(multi: true, minFotos: 2, album: 'OSIRIS Carnet')),
    );
    if (res == null || res.isEmpty) return;
    setState(() { _fotosCarnet = res; _leyendo = true; });
    () async {
      final d = await OcrService.leerCarnetDosLados(res[0], res.length > 1 ? res[1] : null);
      if (!mounted) return;
      setState(() {
        _leyendo = false;
        if (d.nombre != null && _nombre.text.trim().isEmpty) _nombre.text = d.nombre!;
        if (d.ci != null && _ci.text.trim().isEmpty) _ci.text = d.ci!;
      });
    }();
  }

  Future<void> _guardar() async {
    if (_nombre.text.trim().isEmpty) {
      TopToast.show(context, 'Escribe el nombre completo', color: AppColors.rojo, icon: Icons.error_outline);
      return;
    }
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    await db.insert('recurrentes', {
      'nombre': _nombre.text.trim(),
      'ci': _ci.text.trim(),
      'depto': _depto.text.trim(),
      'motivo': _motivo.text.trim(),
      'placa': _placa.text.trim(),
      'foto': _fotosCarnet.isNotEmpty ? _fotosCarnet.first : null,
      'dentro': 0,
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nueva visita recurrente')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Se registra una vez (con foto del carnet). Después bastará un '
              'botón para marcar su ingreso y su salida.', style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _colorRecu, minimumSize: const Size.fromHeight(48)),
              onPressed: _fotoCarnet,
              icon: const Icon(Icons.camera_alt),
              label: Text(_fotosCarnet.isEmpty ? 'Foto del carnet (2 lados)' : 'Repetir carnet (${_fotosCarnet.length})'),
            ),
          ),
          if (_leyendo)
            const Padding(padding: EdgeInsets.only(top: 6), child: Row(children: [
              SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10), Text('Leyendo carnet...'),
            ])),
          if (_fotosCarnet.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(height: 80, child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final f in _fotosCarnet)
                  Padding(padding: const EdgeInsets.only(right: 8),
                      child: ClipRRect(borderRadius: BorderRadius.circular(8),
                          child: Image.file(File(f), width: 110, height: 80, fit: BoxFit.cover))),
              ])),
            ),
          const SizedBox(height: 12),
          TextField(controller: _nombre, textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre y apellido *', prefixIcon: Icon(Icons.person))),
          const SizedBox(height: 12),
          TextField(controller: _ci, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'CI / documento', prefixIcon: Icon(Icons.badge))),
          const SizedBox(height: 12),
          DeptoField(controller: _depto),
          const SizedBox(height: 12),
          TextField(controller: _motivo,
              decoration: const InputDecoration(labelText: 'Motivo (ej. limpieza, delivery)', prefixIcon: Icon(Icons.assignment))),
          const SizedBox(height: 12),
          TextField(controller: _placa, textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Placa vehículo (opcional)', prefixIcon: Icon(Icons.directions_car))),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _colorRecu, minimumSize: const Size.fromHeight(50)),
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
