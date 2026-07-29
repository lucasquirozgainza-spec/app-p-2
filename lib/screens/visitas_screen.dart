import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/contact_launch.dart';
import '../services/ocr_service.dart';
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
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final q = _q.text.trim();
    final where = StringBuffer('edificio=?');
    final args = <dynamic>[ed];
    if (_soloDentro) {
      where.write(" AND estado='dentro'");
    }
    if (q.isNotEmpty) {
      where.write(' AND (nombre_visita LIKE ? OR ci LIKE ? OR depto LIKE ? OR placa LIKE ? OR tarjeta_num LIKE ? OR autoriza LIKE ?)');
      final like = '%$q%';
      args.addAll([like, like, like, like, like, like]);
    }
    final rows = await db.query('visitas', where: where.toString(), whereArgs: args, orderBy: 'id DESC');
    if (!mounted) return;
    setState(() => _visitas = rows);
  }

  Future<void> _registrarSalida(Map<String, dynamic> v) async {
    final tieneTarjeta = (v['tarjeta']?.toString() ?? '').isNotEmpty;
    bool devuelta = true;
    if (tieneTarjeta) {
      final r = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.badge, color: AppColors.azulMarino, size: 36),
          title: const Text('Devolucion de tarjeta'),
          content: Text('¿La visita de ${v['nombre_visita'] ?? ''} (depto ${v['depto'] ?? ''}) devolvio la tarjeta de acceso?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('NO devolvio', style: TextStyle(color: AppColors.rojo))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Si, devolvio')),
          ],
        ),
      );
      if (r == null) return;
      devuelta = r;
    }
    final db = await DB.instance.database;
    await db.update('visitas', {
      'estado': 'salio',
      'hora_salida': DateTime.now().toIso8601String(),
      'tarjeta_devuelta': devuelta ? 1 : 0,
    }, where: 'id=?', whereArgs: [v['id']]);
    if (tieneTarjeta && !devuelta) {
      final guardiaActual = AppState.instance.userNombre ?? 'Sin turno';
      final guardiaAsigno = v['guardia_nombre']?.toString() ?? 'desconocido';
      await db.insert('advertencias', {
        'guardia_nombre': guardiaActual,
        'mensaje': 'Tarjeta NO devuelta - visita ${v['nombre_visita'] ?? ''} (depto ${v['depto'] ?? ''}). '
            'Tarjeta N° ${v['tarjeta_num'] ?? '-'}. La asigno: $guardiaAsigno. Registro la salida: $guardiaActual.',
        'tipo': 'tarjeta',
        'edificio': AppState.instance.edificioId,
        'created_at': DateTime.now().toIso8601String(),
      });
    }
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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _q,
              onChanged: (_) => _load(),
              decoration: const InputDecoration(
                hintText: 'Buscar nombre, CI, depto, placa, N° tarjeta...',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: _visitas.isEmpty
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
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => VisitaDetalle(visita: v))),
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
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class VisitaDetalle extends StatelessWidget {
  final Map<String, dynamic> visita;
  const VisitaDetalle({super.key, required this.visita});

  Widget _foto(String label, Object? path) {
    final p = path?.toString() ?? '';
    if (p.isEmpty || !File(p).existsSync()) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        ClipRRect(borderRadius: BorderRadius.circular(10),
            child: Image.file(File(p), height: 200, width: double.infinity, fit: BoxFit.cover)),
      ]),
    );
  }

  Widget _dato(String label, Object? value) {
    final v = value?.toString() ?? '';
    if (v.isEmpty) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      title: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      subtitle: Text(v, style: const TextStyle(fontSize: 15, color: Colors.black87)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = visita;
    final creado = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(v['created_at'] as String));
    final devuelta = v['tarjeta_devuelta'] == 1;
    final tieneTarjeta = (v['tarjeta']?.toString() ?? '').isNotEmpty || (v['tarjeta_num']?.toString() ?? '').isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(v['nombre_visita']?.toString() ?? 'Visita')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(child: Column(children: [
            _dato('Nombre', v['nombre_visita']),
            _dato('CI', v['ci']),
            _dato('Departamento', v['depto']),
            _dato('Autoriza', v['autoriza']),
            _dato('Motivo', v['motivo']),
            _dato('Placa', v['placa']),
            _dato('N° de tarjeta', v['tarjeta_num']),
            _dato('Guardia', v['guardia_nombre']),
            _dato('Ingreso', creado),
            _dato('Estado', v['estado'] == 'dentro' ? 'Dentro del edificio' : 'Salio'),
            if (tieneTarjeta)
              _dato('Tarjeta', devuelta ? 'Devuelta' : (v['estado'] == 'salio' ? 'NO devuelta' : 'En poder de la visita')),
            _dato('Observaciones', v['observaciones']),
          ])),
          const SizedBox(height: 12),
          _foto('Tarjeta asignada', v['tarjeta']),
          _foto('Carnet anverso', v['foto_ci']),
          _foto('Carnet reverso', v['foto_visitante']),
        ],
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
  final _depto = TextEditingController();
  final _autoriza = TextEditingController();
  final _ci = TextEditingController();
  final _motivo = TextEditingController();
  final _cantidad = TextEditingController(text: '1');
  final _placa = TextEditingController();
  final _obs = TextEditingController();
  final _tarjetaNum = TextEditingController();
  String? _fotoTarjeta;
  bool _ocrLeyendo = false;
  List<String> _deptoSug = [];
  String? _carnetAnverso;
  String? _carnetReverso;
  bool _saving = false;
  final _ahora = DateTime.now();

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: AppColors.rojo));

  Future<void> _ocrTarjeta(String? path) async {
    _fotoTarjeta = path;
    if (path == null) return;
    setState(() => _ocrLeyendo = true);
    final num = await OcrService.leerNumero(path);
    if (!mounted) return;
    setState(() {
      _ocrLeyendo = false;
      if (num != null) _tarjetaNum.text = num;
    });
    if (num != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('N° de tarjeta detectado: $num'), backgroundColor: AppColors.verde));
    }
  }

  Future<void> _ocrCarnet(String? path) async {
    _carnetAnverso = path;
    if (path == null) return;
    final num = await OcrService.leerNumero(path);
    if (!mounted) return;
    if (num != null && _ci.text.trim().isEmpty) {
      setState(() => _ci.text = num);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('CI detectado: $num'), backgroundColor: AppColors.verde));
    }
  }

  Future<void> _sugerirDeptos() async {
    final t = _depto.text.trim();
    if (t.isEmpty) {
      setState(() => _deptoSug = []);
      return;
    }
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final rows = await db.rawQuery(
        'SELECT DISTINCT depto FROM propietarios WHERE edificio=? AND depto LIKE ? ORDER BY depto LIMIT 8',
        [ed, '$t%']);
    final sug = rows.map((r) => r['depto'].toString()).where((d) => d.isNotEmpty && d != t).toList();
    if (!mounted) return;
    setState(() => _deptoSug = sug);
  }

  Future<List<Map<String, dynamic>>> _consultarContactos(String depto) async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final out = <Map<String, dynamic>>[];
    final props = await db.query('propietarios', where: 'edificio=? AND depto=?', whereArgs: [ed, depto]);
    for (final p in props) {
      if ((p['copropietario']?.toString() ?? '').isNotEmpty) {
        out.add({'nombre': p['copropietario'], 'tel': p['telefono'], 'rol': 'Propietario'});
      }
      if ((p['inquilino']?.toString() ?? '').isNotEmpty) {
        out.add({'nombre': p['inquilino'], 'tel': p['telefono_inq'], 'rol': 'Inquilino'});
      }
    }
    final resis = await db.query('residentes', where: 'edificio=? AND depto=?', whereArgs: [ed, depto]);
    for (final r in resis) {
      out.add({'nombre': r['nombre'], 'tel': r['celular'], 'rol': 'Residente'});
    }
    return out;
  }

  Future<void> _mostrarContactos() async {
    final depto = _depto.text.trim();
    if (depto.isEmpty) return _snack('Primero escribe el departamento');
    final contactos = await _consultarContactos(depto);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Depto $depto'),
        content: SizedBox(
          width: double.maxFinite,
          child: contactos.isEmpty
              ? const Padding(padding: EdgeInsets.all(8), child: Text('No hay personas registradas para ese departamento.'))
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in contactos)
                      _ContactoCard(
                        nombre: c['nombre']?.toString() ?? '',
                        rol: c['rol']?.toString() ?? '',
                        tel: c['tel']?.toString() ?? '',
                        onLlamar: () => Contacto.llamar(context, c['tel'].toString()),
                        onWhatsapp: () => Contacto.whatsapp(context, c['tel'].toString(),
                            mensaje: 'Tiene una visita: ${_nombre.text}. ¿Autoriza el ingreso al depto $depto?'),
                        onElegir: () {
                          setState(() => _autoriza.text = c['nombre']?.toString() ?? '');
                          Navigator.pop(context);
                        },
                      ),
                  ],
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
      ),
    );
  }

  Future<void> _guardar() async {
    if (_nombre.text.trim().isEmpty) return _snack('Ingrese el nombre del visitante');
    if (_carnetAnverso == null) return _snack('La foto del carnet (anverso) es obligatoria');
    if (_carnetReverso == null) return _snack('La foto del carnet (reverso) es obligatoria');
    setState(() => _saving = true);
    final s = AppState.instance;
    final gps = await DeviceContext.gps();
    final disp = await DeviceContext.dispositivo();
    final db = await DB.instance.database;
    final id = await db.insert('visitas', {
      'guardia_id': s.userId,
      'guardia_nombre': s.userNombre,
      'tarjeta': _fotoTarjeta,
      'tarjeta_num': _tarjetaNum.text.trim(),
      'nombre_visita': _nombre.text.trim(),
      'ci': _ci.text,
      'foto_ci': _carnetAnverso,
      'foto_visitante': _carnetReverso,
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
    await Cloud.evento('Visita', detalle: {'nombre': _nombre.text.trim(), 'depto': _depto.text, 'motivo': _motivo.text});
    if (!mounted) return;
    Navigator.pop(context);
  }

  Widget _paso(String n, String t) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 8),
        child: Row(children: [
          CircleAvatar(radius: 12, backgroundColor: AppColors.azulMarino,
              child: Text(n, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))),
          const SizedBox(width: 8),
          Expanded(child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Registrar Visita')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _paso('1', 'Datos del visitante'),
        TextField(controller: _nombre, textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Nombre del visitante *')),
        const SizedBox(height: 12),
        TextField(controller: _depto,
            decoration: const InputDecoration(
              labelText: 'Departamento a visitar *',
              prefixIcon: Icon(Icons.meeting_room),
            ),
            onChanged: (_) => _sugerirDeptos()),
        if (_deptoSug.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final d in _deptoSug)
                ActionChip(
                  label: Text(d),
                  backgroundColor: AppColors.grisClaro,
                  onPressed: () {
                    _depto.text = d;
                    setState(() => _deptoSug = []);
                    _mostrarContactos();
                  },
                ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _mostrarContactos,
            icon: const Icon(Icons.people),
            label: const Text('Ver contactos del depto y autorizar'),
          ),
        ),
        const SizedBox(height: 12),
        TextField(controller: _autoriza,
            decoration: const InputDecoration(
              labelText: 'Persona que autoriza',
              prefixIcon: Icon(Icons.how_to_reg),
            )),
        const SizedBox(height: 8),
        _paso('3', 'Asignar tarjeta de acceso'),
        PhotoField(
          label: 'Foto de la tarjeta (lee el numero solo)',
          onChanged: _ocrTarjeta,
        ),
        Row(children: [
          Expanded(
            child: TextField(controller: _tarjetaNum,
                decoration: const InputDecoration(labelText: 'N° de tarjeta (automatico o manual)')),
          ),
          if (_ocrLeyendo)
            const Padding(padding: EdgeInsets.only(left: 8),
                child: SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.5))),
        ]),
        const SizedBox(height: 12),
        _paso('4', 'Carnet del visitante y datos'),
        PhotoField(label: 'Carnet ANVERSO (lee el CI solo)', obligatoria: true, onChanged: _ocrCarnet),
        PhotoField(label: 'Carnet REVERSO', obligatoria: true, onChanged: (v) => _carnetReverso = v),
        TextField(controller: _ci, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Numero de CI')),
        const SizedBox(height: 12),
        TextField(controller: _motivo, decoration: const InputDecoration(labelText: 'Motivo')),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: _cantidad, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Cant. personas'))),
          const SizedBox(width: 10),
          Expanded(child: TextField(controller: _placa,
              decoration: const InputDecoration(labelText: 'Placa (opcional)'))),
        ]),
        const SizedBox(height: 12),
        TextField(controller: _obs, maxLines: 2, decoration: const InputDecoration(labelText: 'Observaciones')),
        const SizedBox(height: 12),
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
      ]),
    );
  }
}

// ---------------------------------------------------------------------------

class _ContactoCard extends StatelessWidget {
  final String nombre;
  final String rol;
  final String tel;
  final VoidCallback onLlamar;
  final VoidCallback onWhatsapp;
  final VoidCallback onElegir;
  const _ContactoCard({
    required this.nombre,
    required this.rol,
    required this.tel,
    required this.onLlamar,
    required this.onWhatsapp,
    required this.onElegir,
  });

  @override
  Widget build(BuildContext context) {
    final tieneTel = tel.trim().isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const CircleAvatar(
                  radius: 18,
                  backgroundColor: Color(0x1A0A335D),
                  child: Icon(Icons.person, color: AppColors.azulMarino, size: 20)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nombre,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    Text('$rol${tieneTel ? '  ·  $tel' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.black54, fontSize: 12)),
                  ],
                ),
              ),
            ]),
            if (tieneTel) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.verde, minimumSize: const Size.fromHeight(46)),
                  onPressed: onWhatsapp,
                  icon: const Icon(Icons.chat, size: 18),
                  label: const Text('Llamar por WhatsApp'),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  onPressed: onLlamar,
                  icon: const Icon(Icons.call, size: 18),
                  label: const Text('Llamada normal'),
                ),
              ),
            ],
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: onElegir,
                icon: const Icon(Icons.check_circle, size: 18),
                label: const Text('Elegir como quien autoriza'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
