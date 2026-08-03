import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../theme.dart';
import '../widgets/depto_field.dart';
import '../widgets/toast.dart';
import 'camera_screen.dart';

// WhatsApp es la forma mas comun de confirmar hospedaje -> por defecto.
const _plataformas = ['WhatsApp', 'Airbnb', 'Booking', 'Directo', 'Otro'];
const _tealC = Color(0xFF00838F);

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

  /// Marca la salida REAL del huesped (con fecha y hora del momento) y calcula
  /// cuantos dias se quedo. Sirve si el huesped se fue un dia mas tarde.
  Future<void> _marcarSalida(Map<String, dynamic> x) async {
    final ahora = DateTime.now();
    final dias = _diasEstadia(x, ahora);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.logout, color: _tealC, size: 36),
        title: const Text('Marcar salida'),
        content: Text('Se registrará la salida el ${DateFormat('dd/MM/yyyy HH:mm').format(ahora)}.'
            '${dias != null ? '\nEstadía: $dias día(s).' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _tealC),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Marcar salida'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final db = await DB.instance.database;
    await db.update('hospedajes',
        {'estado': 'finalizado', 'salida_real': ahora.toIso8601String()},
        where: 'id=?', whereArgs: [x['id']]);
    await Audit.log('EDITAR', 'hospedajes', '${x['id']}', detalle: 'salida real');
    _load();
  }

  /// Dias entre el ingreso y [hasta] (mínimo 1).
  static int? _diasEstadia(Map<String, dynamic> x, DateTime hasta) {
    try {
      final ing = DateTime.parse((x['fecha_ingreso'] ?? '').toString());
      final d = hasta.difference(ing).inHours / 24.0;
      return d < 1 ? 1 : d.ceil();
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> get _filtrados {
    final q = _buscar.text.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows.where((x) {
      final s = '${x['depto']} ${x['huesped']} ${x['documento']} ${x['plataforma']}'.toLowerCase();
      return s.contains(q);
    }).toList();
  }

  String _ingresoCorto(Map<String, dynamic> x) {
    final raw = (x['fecha_ingreso'] ?? '').toString();
    try {
      return DateFormat('dd/MM HH:mm').format(DateTime.parse(raw));
    } catch (_) {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtrados;
    return Scaffold(
      appBar: AppBar(title: const Text('Hospedajes')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _tealC,
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
                hintText: 'Buscar por depto, huésped o documento',
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
                      final noches = x['noches'];
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
                                  backgroundColor: (activo ? _tealC : Colors.grey).withOpacity(.15),
                                  child: Icon(Icons.hotel, color: activo ? _tealC : Colors.grey),
                                ),
                          title: Text('Depto ${x['depto']} · ${x['huesped'] ?? ''}',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                              'Ingreso ${_ingresoCorto(x)} · ${noches ?? '?'} noche(s) · ${x['cantidad'] ?? 1} huésped(es)',
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: activo
                              ? TextButton(onPressed: () => _marcarSalida(x), child: const Text('Salida'))
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

/// Un huésped del hospedaje: nombre completo + tipo de documento + fotos.
class _Huesped {
  final nombre = TextEditingController();
  String tipo = 'Carnet'; // Carnet (2 fotos) | Pasaporte (1 foto)
  List<String> fotos = [];
}

class HospedajeForm extends StatefulWidget {
  const HospedajeForm({super.key});
  @override
  State<HospedajeForm> createState() => _HospedajeFormState();
}

class _HospedajeFormState extends State<HospedajeForm> {
  final _depto = TextEditingController();
  final _noches = TextEditingController(text: '1');
  final _placa = TextEditingController();
  final _obs = TextEditingController();
  String _plataforma = _plataformas.first;
  late DateTime _ingreso;
  bool _saving = false;
  final List<_Huesped> _huespedes = [_Huesped()]; // el primero es el principal

  @override
  void initState() {
    super.initState();
    _ingreso = DateTime.now(); // ingreso automático: ahora
  }

  @override
  void dispose() {
    _depto.dispose();
    _noches.dispose();
    _placa.dispose();
    _obs.dispose();
    for (final h in _huespedes) {
      h.nombre.dispose();
    }
    super.dispose();
  }

  int get _n => int.tryParse(_noches.text.trim()) ?? 1;
  DateTime get _salidaEsperada => DateTime(_ingreso.year, _ingreso.month, _ingreso.day + (_n < 1 ? 1 : _n));

  Future<void> _fotosDoc(_Huesped h) async {
    final carnet = h.tipo == 'Carnet';
    final res = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => CameraScreen(
          multi: carnet, // carnet: anverso + reverso; pasaporte: una sola
          minFotos: carnet ? 2 : 0,
          album: 'OSIRIS Documentos',
        ),
      ),
    );
    if (res != null && res.isNotEmpty) setState(() => h.fotos = res);
  }

  Future<void> _guardar() async {
    final principal = _huespedes.first;
    if (principal.nombre.text.trim().isEmpty) {
      return _snack('Escribe el nombre y apellido del huésped principal');
    }
    for (int i = 0; i < _huespedes.length; i++) {
      final h = _huespedes[i];
      if (h.nombre.text.trim().isEmpty) return _snack('Falta el nombre del huésped ${i + 1}');
      if (h.fotos.isEmpty) return _snack('Falta la foto del documento del huésped ${i + 1}');
    }
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    final huespedesData = [
      for (final h in _huespedes)
        {'nombre': h.nombre.text.trim(), 'tipo': h.tipo, 'fotos': h.fotos}
    ];
    final id = await db.insert('hospedajes', {
      'guardia_nombre': s.userNombre,
      'plataforma': _plataforma,
      'huesped': principal.nombre.text.trim(),
      'documento': '',
      'foto_doc': principal.fotos.isNotEmpty ? principal.fotos.first : null,
      'huespedes_json': jsonEncode(huespedesData),
      'depto': _depto.text.trim(),
      'fecha_ingreso': _ingreso.toIso8601String(),
      'fecha_salida': DateFormat('dd/MM/yyyy').format(_salidaEsperada),
      'noches': _n,
      'cantidad': _huespedes.length,
      'placa': _placa.text.trim(),
      'observaciones': _obs.text.trim(),
      'estado': 'activo',
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'hospedajes', '$id');
    // Nube en segundo plano (no demora el registro).
    final fotoNube = principal.fotos.isNotEmpty ? principal.fotos.first : null;
    final det = {
      'huesped': principal.nombre.text.trim(),
      'depto': _depto.text.trim(),
      'plataforma': _plataforma,
      'noches': '$_n',
      'huespedes': '${_huespedes.length}',
    };
    () async {
      final url = fotoNube != null ? await Cloud.subirFoto(fotoNube) : null;
      await Cloud.evento('Hospedaje', detalle: {...det, if (url != null) 'foto_url': url});
    }();
    if (!mounted) return;
    Navigator.pop(context);
  }

  void _snack(String m) {
    setState(() => _saving = false);
    TopToast.show(context, m, color: AppColors.rojo, icon: Icons.error_outline);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nuevo Hospedaje')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Ingreso automático (fecha y hora del momento).
          Card(
            color: const Color(0x1400838F),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.login, color: _tealC),
              title: const Text('Ingreso (automático)'),
              subtitle: Text(DateFormat('dd/MM/yyyy · HH:mm').format(_ingreso)),
            ),
          ),
          const SizedBox(height: 12),
          DeptoField(controller: _depto),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _noches,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Noches', prefixIcon: Icon(Icons.nightlight_round)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Salida esperada'),
                child: Text(DateFormat('dd/MM/yyyy').format(_salidaEsperada)),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _plataforma,
            decoration: const InputDecoration(labelText: 'Plataforma / confirmación'),
            items: [for (final p in _plataformas) DropdownMenuItem(value: p, child: Text(p))],
            onChanged: (v) => setState(() => _plataforma = v ?? _plataforma),
          ),
          const SizedBox(height: 16),
          const Text('Huéspedes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Text('Cada huésped con su nombre y foto del documento (carnet: 2 fotos, pasaporte: 1).',
              style: TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 8),
          for (int i = 0; i < _huespedes.length; i++) _tarjetaHuesped(i),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: () => setState(() => _huespedes.add(_Huesped())),
            icon: const Icon(Icons.person_add),
            label: const Text('Agregar huésped'),
          ),
          const SizedBox(height: 12),
          TextField(controller: _placa, decoration: const InputDecoration(labelText: 'Placa vehículo (opcional)')),
          const SizedBox(height: 12),
          TextField(controller: _obs, maxLines: 2, decoration: const InputDecoration(labelText: 'Observaciones')),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _tealC, minimumSize: const Size.fromHeight(50)),
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

  Widget _tarjetaHuesped(int i) {
    final h = _huespedes[i];
    final carnet = h.tipo == 'Carnet';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(radius: 13, backgroundColor: _tealC,
                  child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))),
              const SizedBox(width: 8),
              Text(i == 0 ? 'Huésped principal' : 'Acompañante $i',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (i > 0)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, color: AppColors.rojo),
                  onPressed: () => setState(() {
                    _huespedes[i].nombre.dispose();
                    _huespedes.removeAt(i);
                  }),
                ),
            ]),
            const SizedBox(height: 4),
            TextField(
              controller: h.nombre,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre y apellido completo'),
            ),
            const SizedBox(height: 8),
            Row(children: [
              ChoiceChip(
                label: const Text('Carnet'),
                selected: carnet,
                selectedColor: _tealC,
                labelStyle: TextStyle(color: carnet ? Colors.white : null, fontWeight: FontWeight.w600),
                onSelected: (_) => setState(() { h.tipo = 'Carnet'; h.fotos = []; }),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Pasaporte'),
                selected: !carnet,
                selectedColor: _tealC,
                labelStyle: TextStyle(color: !carnet ? Colors.white : null, fontWeight: FontWeight.w600),
                onSelected: (_) => setState(() { h.tipo = 'Pasaporte'; h.fotos = []; }),
              ),
            ]),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _tealC),
                onPressed: () => _fotosDoc(h),
                icon: const Icon(Icons.camera_alt, size: 18),
                label: Text(h.fotos.isEmpty
                    ? (carnet ? 'Fotos del carnet (2 lados)' : 'Foto del pasaporte')
                    : 'Repetir fotos (${h.fotos.length})'),
              ),
            ),
            if (h.fotos.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 70,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final f in h.fotos)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(File(f), width: 70, height: 70, fit: BoxFit.cover),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class HospedajeDetalle extends StatelessWidget {
  final Map<String, dynamic> row;
  const HospedajeDetalle({super.key, required this.row});

  List<Map<String, dynamic>> get _huespedes {
    try {
      final raw = row['huespedes_json'];
      if (raw is String && raw.isNotEmpty) {
        return List<Map<String, dynamic>>.from(jsonDecode(raw) as List);
      }
    } catch (_) {}
    return [];
  }

  String _fmt(String? iso, {bool hora = false}) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final d = DateTime.parse(iso);
      return DateFormat(hora ? 'dd/MM/yyyy HH:mm' : 'dd/MM/yyyy').format(d);
    } catch (_) {
      return iso;
    }
  }

  Widget _dato(IconData ic, String label, String? valor) {
    if (valor == null || valor.trim().isEmpty) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      leading: Icon(ic, color: _tealC),
      title: Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      subtitle: Text(valor, style: const TextStyle(fontSize: 15, color: Colors.black87)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final huespedes = _huespedes;
    final ingreso = (row['fecha_ingreso'] ?? '').toString();
    final salidaReal = (row['salida_real'] ?? '').toString();
    String? dias;
    if (salidaReal.isNotEmpty) {
      try {
        final d = DateTime.parse(salidaReal).difference(DateTime.parse(ingreso)).inHours / 24.0;
        dias = '${d < 1 ? 1 : d.ceil()} día(s)';
      } catch (_) {}
    }
    return Scaffold(
      appBar: AppBar(title: Text('Depto ${row['depto']}')),
      body: ListView(
        children: [
          _dato(Icons.login, 'Ingreso', _fmt(ingreso, hora: true)),
          _dato(Icons.nightlight_round, 'Noches', row['noches'] != null ? '${row['noches']}' : null),
          _dato(Icons.event, 'Salida esperada', (row['fecha_salida'] ?? '').toString()),
          _dato(Icons.logout, 'Salida real', _fmt(salidaReal, hora: true)),
          _dato(Icons.timelapse, 'Estadía', dias),
          _dato(Icons.chat, 'Plataforma', row['plataforma'] as String?),
          _dato(Icons.directions_car, 'Placa', row['placa'] as String?),
          _dato(Icons.notes, 'Observaciones', row['observaciones'] as String?),
          _dato(Icons.badge_outlined, 'Registrado por', row['guardia_nombre'] as String?),
          _dato(Icons.info_outline, 'Estado', row['estado'] as String?),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Huéspedes (${huespedes.isEmpty ? 1 : huespedes.length})',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          if (huespedes.isEmpty)
            // Registro antiguo: solo el huésped principal con una foto.
            _bloqueHuesped(context, row['huesped']?.toString() ?? '', 'Documento',
                [if ((row['foto_doc'] ?? '').toString().isNotEmpty) row['foto_doc'].toString()])
          else
            for (final h in huespedes)
              _bloqueHuesped(context, h['nombre']?.toString() ?? '', h['tipo']?.toString() ?? '',
                  (h['fotos'] is List) ? List<String>.from(h['fotos']) : const []),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _bloqueHuesped(BuildContext context, String nombre, String tipo, List<String> fotos) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.person, color: _tealC, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(nombre, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
              if (tipo.isNotEmpty)
                Text(tipo, style: const TextStyle(color: Colors.black54, fontSize: 12)),
            ]),
            if (fotos.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 110,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final f in fotos)
                      if (File(f).existsSync())
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: () => showDialog(
                              context: context,
                              builder: (_) => Dialog(child: InteractiveViewer(child: Image.file(File(f)))),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(File(f), width: 150, height: 110, fit: BoxFit.cover),
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
