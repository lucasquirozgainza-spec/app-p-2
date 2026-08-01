import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/ocr_service.dart';
import '../theme.dart';
import '../widgets/photo_field.dart';
import '../widgets/depto_field.dart';
import '../widgets/toast.dart';

// WhatsApp es la forma mas comun de confirmar hospedaje -> por defecto.
const _plataformas = ['WhatsApp', 'Airbnb', 'Booking', 'Directo', 'Otro'];

class HospedajesScreen extends StatefulWidget {
  const HospedajesScreen({super.key});
  @override
  State<HospedajesScreen> createState() => _HospedajesScreenState();
}

class _HospedajesScreenState extends State<HospedajesScreen> {
  List<Map<String, dynamic>> _rows = [];
  final _buscar = TextEditingController();

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

  List<Map<String, dynamic>> get _filtrados {
    final q = _buscar.text.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows.where((x) {
      final s = '${x['depto']} ${x['huesped']} ${x['documento']} ${x['plataforma']}'.toLowerCase();
      return s.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtrados;
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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _buscar,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Buscar por depto, huesped o documento',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('Sin hospedajes'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final x = rows[i];
                      final activo = x['estado'] == 'activo';
                      final foto = x['foto_doc'] as String?;
                      return Card(
                        child: ListTile(
                          onTap: () async {
                            await Navigator.push(context,
                                MaterialPageRoute(builder: (_) => HospedajeDetalle(row: x)));
                            _load();
                          },
                          leading: (foto != null && foto.isNotEmpty && File(foto).existsSync())
                              ? CircleAvatar(backgroundImage: FileImage(File(foto)))
                              : CircleAvatar(
                                  backgroundColor: (activo ? const Color(0xFF00838F) : Colors.grey).withOpacity(.15),
                                  child: Icon(Icons.hotel, color: activo ? const Color(0xFF00838F) : Colors.grey),
                                ),
                          title: Text('Depto ${x['depto']} · ${x['huesped'] ?? ''}',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                              '${x['plataforma'] ?? ''} · ${x['fecha_ingreso'] ?? ''} → ${x['fecha_salida'] ?? ''}\n${x['cantidad'] ?? 1} huesped(es)',
                              maxLines: 3, overflow: TextOverflow.ellipsis),
                          isThreeLine: true,
                          trailing: activo
                              ? TextButton(onPressed: () => _finalizar(x), child: const Text('Cerrar'))
                              : const Icon(Icons.done, color: Colors.grey),
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
  bool _ocr = false;

  @override
  void initState() {
    super.initState();
    // Registro de ingreso automatico: por defecto hoy.
    _ingreso = DateTime.now();
  }

  @override
  void dispose() {
    _huesped.dispose();
    _doc.dispose();
    _depto.dispose();
    _cantidad.dispose();
    _placa.dispose();
    _obs.dispose();
    super.dispose();
  }

  Future<void> _pickFecha(bool ingreso) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: ingreso ? (_ingreso ?? now) : (_salida ?? now),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (d != null) setState(() => ingreso ? _ingreso = d : _salida = d);
  }

  String _fmt(DateTime? d) => d == null ? 'Seleccionar' : DateFormat('dd/MM/yyyy').format(d);

  // Lee la foto del documento (carnet o pasaporte) y autocompleta nombre + numero.
  Future<void> _procesarDoc(String? path) async {
    _fotoDoc = path;
    if (path == null) return;
    setState(() => _ocr = true);
    try {
      final texto = await OcrService.leerTexto(path);
      final carnet = OcrService.parseCarnet(texto);
      if (carnet.nombre != null && _huesped.text.trim().isEmpty) {
        _huesped.text = carnet.nombre!;
      }
      if (carnet.ci != null && _doc.text.trim().isEmpty) {
        _doc.text = carnet.ci!;
      }
      // Pasaporte: si no hubo CI, intentar un numero/codigo largo del texto.
      if (_doc.text.trim().isEmpty) {
        final m = RegExp(r'[A-Z0-9]{7,}').firstMatch(texto.toUpperCase().replaceAll(' ', ''));
        if (m != null) _doc.text = m.group(0)!;
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _ocr = false);
        TopToast.show(context, 'Documento leído. Revisa nombre y número.');
      }
    }
  }

  Future<void> _guardar() async {
    if (_huesped.text.trim().isEmpty || _fotoDoc == null) {
      TopToast.show(context, 'Nombre y foto del documento son obligatorios', color: AppColors.rojo, icon: Icons.error_outline);
      return;
    }
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    final id = await db.insert('hospedajes', {
      'guardia_nombre': s.userNombre,
      'plataforma': _plataforma,
      'huesped': _huesped.text.trim(),
      'documento': _doc.text.trim(),
      'foto_doc': _fotoDoc,
      'depto': _depto.text.trim(),
      'fecha_ingreso': _ingreso == null ? '' : DateFormat('dd/MM/yyyy').format(_ingreso!),
      'fecha_salida': _salida == null ? '' : DateFormat('dd/MM/yyyy').format(_salida!),
      'cantidad': int.tryParse(_cantidad.text) ?? 1,
      'placa': _placa.text.trim(),
      'observaciones': _obs.text.trim(),
      'estado': 'activo',
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'hospedajes', '$id');
    await Cloud.evento('Hospedaje', detalle: {
      'huesped': _huesped.text.trim(),
      'depto': _depto.text.trim(),
      'plataforma': _plataforma,
    });
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
          const Text('Foto del documento (carnet o pasaporte)',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          PhotoField(label: 'Foto del documento', obligatoria: true, album: 'OSIRIS Documentos', onChanged: _procesarDoc),
          if (_ocr)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Row(children: [
                SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('Leyendo documento...'),
              ]),
            ),
          const SizedBox(height: 12),
          TextField(controller: _huesped, decoration: const InputDecoration(labelText: 'Huesped principal *')),
          const SizedBox(height: 12),
          TextField(controller: _doc, decoration: const InputDecoration(labelText: 'Documento / pasaporte')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _plataforma,
            decoration: const InputDecoration(labelText: 'Plataforma / confirmacion'),
            items: [for (final p in _plataformas) DropdownMenuItem(value: p, child: Text(p))],
            onChanged: (v) => setState(() => _plataforma = v ?? _plataforma),
          ),
          const SizedBox(height: 12),
          DeptoField(controller: _depto),
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

class HospedajeDetalle extends StatelessWidget {
  final Map<String, dynamic> row;
  const HospedajeDetalle({super.key, required this.row});

  Widget _dato(IconData ic, String label, String? valor) {
    if (valor == null || valor.trim().isEmpty) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      leading: Icon(ic, color: const Color(0xFF00838F)),
      title: Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      subtitle: Text(valor, style: const TextStyle(fontSize: 15, color: Colors.black87)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final foto = row['foto_doc'] as String?;
    return Scaffold(
      appBar: AppBar(title: Text('Depto ${row['depto']}')),
      body: ListView(
        children: [
          if (foto != null && foto.isNotEmpty && File(foto).existsSync())
            GestureDetector(
              onTap: () => showDialog(
                context: context,
                builder: (_) => Dialog(
                  child: InteractiveViewer(child: Image.file(File(foto))),
                ),
              ),
              child: Image.file(File(foto), height: 240, width: double.infinity, fit: BoxFit.cover),
            ),
          _dato(Icons.person, 'Huesped', row['huesped'] as String?),
          _dato(Icons.badge, 'Documento', row['documento'] as String?),
          _dato(Icons.apartment, 'Departamento', row['depto'] as String?),
          _dato(Icons.chat, 'Plataforma', row['plataforma'] as String?),
          _dato(Icons.login, 'Ingreso', row['fecha_ingreso'] as String?),
          _dato(Icons.logout, 'Salida', row['fecha_salida'] as String?),
          _dato(Icons.groups, 'Nro huespedes', '${row['cantidad'] ?? 1}'),
          _dato(Icons.directions_car, 'Placa', row['placa'] as String?),
          _dato(Icons.notes, 'Observaciones', row['observaciones'] as String?),
          _dato(Icons.badge_outlined, 'Registrado por', row['guardia_nombre'] as String?),
          _dato(Icons.info_outline, 'Estado', row['estado'] as String?),
        ],
      ),
    );
  }
}
