import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/contact_launch.dart';
import '../services/contactos_repo.dart';
import '../theme.dart';
import '../widgets/photo_field.dart';
import '../widgets/depto_field.dart';
import '../widgets/toast.dart';
import '../widgets/eventos_remotos.dart';

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
      body: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length + 1,
              itemBuilder: (_, i) {
                if (i == _rows.length) {
                  return const EventosRemotos(tipo: 'Encomienda', icon: Icons.inventory_2,
                      color: Color(0xFFEF6C00), tituloKeys: ['depto', 'destinatario']);
                }
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
      TopToast.show(context, 'La foto del paquete es obligatoria', color: AppColors.rojo, icon: Icons.error_outline);
      return;
    }
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    final id = await db.insert('encomiendas', {
      'guardia_nombre': s.userNombre,
      'foto': _foto,
      'depto': _depto.text.trim(),
      'destinatario': _dest.text.trim(),
      'empresa': _empresa.text.trim(),
      'estado': 'pendiente',
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'encomiendas', '$id');
    await Cloud.evento('Encomienda', detalle: {
      'depto': _depto.text.trim(),
      'destinatario': _dest.text.trim(),
      'empresa': _empresa.text.trim(),
    });
    if (!mounted) return;
    await _avisarDepto();
    if (!mounted) return;
    Navigator.pop(context);
  }

  /// Tras guardar, ofrece avisar al residente del depto por WhatsApp
  /// ("ya llego tu pedido"), con opcion de enviar la foto del paquete.
  Future<void> _avisarDepto() async {
    final depto = _depto.text.trim();
    if (depto.isEmpty) return;
    final contactos = await ContactosRepo.delDepto(depto);
    // El encargado (si se marcó) va primero como contacto predeterminado.
    final enc = await ContactosRepo.encargado(depto);
    if (enc != null && enc.tel.trim().isNotEmpty) {
      contactos.removeWhere((c) => c.nombre == enc.nombre && c.tel == enc.tel);
      contactos.insert(0, enc);
    }
    if (!mounted || contactos.isEmpty) return;
    final msg = '📦 Encomienda para el depto $depto'
        '${_dest.text.trim().isNotEmpty ? ' (${_dest.text.trim()})' : ''}. '
        'Ya llegó tu pedido y está en portería. — ${AppState.instance.edificioNombre}';
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Avisar al depto $depto'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final c in contactos.where((c) => c.tel.trim().isNotEmpty))
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${c.nombre}  ·  ${c.rol}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(c.tel, style: const TextStyle(color: Colors.black54, fontSize: 12)),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: AppColors.verde, minimumSize: const Size.fromHeight(44)),
                          onPressed: () => Contacto.whatsapp(context, c.tel, mensaje: msg),
                          icon: const Icon(Icons.message, size: 18),
                          label: const Text('Enviar mensaje'),
                        ),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: AppColors.azulMarino, minimumSize: const Size.fromHeight(44)),
                          onPressed: () {
                            // Enviar por WhatsApp CON la foto del paquete.
                            if (_foto != null && File(_foto!).existsSync()) {
                              Share.shareXFiles([XFile(_foto!)], text: '$msg\n📱 ${c.nombre}: ${c.tel}');
                            } else {
                              Contacto.whatsapp(context, c.tel, mensaje: msg);
                            }
                          },
                          icon: const Icon(Icons.photo_camera, size: 18),
                          label: const Text('Enviar con foto'),
                        ),
                      ),
                    ]),
                  ),
                ),
              if (contactos.every((c) => c.tel.trim().isEmpty))
                const Padding(padding: EdgeInsets.all(8), child: Text('Los contactos del depto no tienen teléfono registrado.')),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Listo'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nueva Encomienda')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PhotoField(label: 'Foto del paquete', obligatoria: true, album: 'OSIRIS Encomiendas', onChanged: (v) => _foto = v),
          DeptoField(controller: _depto),
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
      TopToast.show(context, 'Tome la foto del residente recibiendo', color: AppColors.rojo, icon: Icons.error_outline);
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
          PhotoField(label: 'Foto del residente recibiendo', obligatoria: true, album: 'OSIRIS Encomiendas', onChanged: (v) => _foto = v),
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
