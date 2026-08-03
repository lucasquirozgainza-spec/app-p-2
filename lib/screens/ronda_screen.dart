import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/dvr.dart';
import '../theme.dart';
import '../widgets/toast.dart';
import 'camera_screen.dart';

class RondaScreen extends StatefulWidget {
  const RondaScreen({super.key});
  @override
  State<RondaScreen> createState() => _RondaScreenState();
}

class _RondaScreenState extends State<RondaScreen> {
  final List<String> _fotos = [];
  final _obs = TextEditingController();
  bool _saving = false;
  final _inicio = DateTime.now();

  // Puntos de control (opcional). Si el edificio no tiene, la ronda es normal.
  List<Map<String, dynamic>> _puntos = [];
  final Set<String> _escaneados = {};

  // Cantidad de fotos obligatorias por ronda (configurable por el admin).
  int get _min => AppState.instance.rondaFotos;

  @override
  void initState() {
    super.initState();
    _cargarPuntos();
  }

  Future<void> _cargarPuntos() async {
    final db = await DB.instance.database;
    final rows = await db.query('puntos_control',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'id');
    if (!mounted) return;
    setState(() => _puntos = rows);
  }

  Future<void> _escanearPunto() async {
    final res = await Navigator.push<List<String>>(
        context, MaterialPageRoute(builder: (_) => const CameraScreen(multi: false)));
    if (res == null || res.isEmpty) return;
    final raw = await Dvr.leerQr(res.first);
    if (!mounted) return;
    if (raw == null) {
      TopToast.show(context, 'No se leyó el QR. Acércate al punto.', color: AppColors.rojo, icon: Icons.error_outline);
      return;
    }
    final punto = _puntos.where((p) => p['codigo']?.toString() == raw.trim()).toList();
    if (punto.isEmpty) {
      TopToast.show(context, 'Ese QR no es un punto de este edificio.', color: AppColors.rojo, icon: Icons.error_outline);
      return;
    }
    setState(() => _escaneados.add(raw.trim()));
    TopToast.show(context, 'Punto: ${punto.first['nombre']} ✓');
  }

  void _snack(String m) => TopToast.show(context, m, color: AppColors.rojo, icon: Icons.error_outline);

  Future<void> _tomarFotos() async {
    final res = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(builder: (_) => CameraScreen(multi: true, minFotos: _min, album: 'OSIRIS Rondas')),
    );
    if (res != null && res.isNotEmpty) setState(() => _fotos.addAll(res));
  }

  Future<void> _guardar() async {
    if (_fotos.length < _min) {
      return _snack('Debes tomar al menos $_min fotos (llevas ${_fotos.length})');
    }
    // Si el edificio tiene puntos y faltan por escanear, pedir confirmacion.
    if (_puntos.isNotEmpty && _escaneados.length < _puntos.length) {
      final seguir = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.qr_code_scanner, color: Color(0xFFEF6C00), size: 36),
          title: const Text('Faltan puntos'),
          content: Text('Escaneaste ${_escaneados.length} de ${_puntos.length} puntos. ¿Guardar la ronda igual?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Seguir escaneando')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Guardar igual')),
          ],
        ),
      );
      if (seguir != true) return;
    }
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    final escaneadosDetalle = _puntos
        .where((p) => _escaneados.contains(p['codigo']?.toString()))
        .map((p) => {'nombre': p['nombre'], 'codigo': p['codigo']})
        .toList();
    final id = await db.insert('rondas', {
      'guardia_id': s.userId,
      'guardia_nombre': s.userNombre,
      'puntos': jsonEncode({'fotos_ronda': _fotos, 'puntos_escaneados': escaneadosDetalle}),
      'observaciones': _obs.text,
      'con_novedad': 0,
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'rondas', '$id');

    // Subida a la nube en SEGUNDO PLANO (no demora el WhatsApp): sube hasta 6
    // fotos comprimidas para verlas desde otros equipos y publica el evento.
    final fotosCopia = List<String>.from(_fotos);
    final puntosTxt = _puntos.isNotEmpty ? '${_escaneados.length}/${_puntos.length}' : null;
    () async {
      final fotosUrl = await Cloud.subirFotos(fotosCopia, max: 6);
      await Cloud.evento('Ronda', detalle: {
        'fotos': fotosCopia.length,
        if (puntosTxt != null) 'puntos': puntosTxt,
        if (fotosUrl.isNotEmpty) 'fotos_url': fotosUrl,
      });
    }();

    // Compartir las fotos por WhatsApp en 1 clic, a la resolución máxima.
    final guardia = s.userNombre ?? 'Guardia';
    final msg = _obs.text.trim().isEmpty
        ? 'Ronda sin novedad - $guardia - ${DateFormat('dd/MM HH:mm').format(DateTime.now())}'
        : 'Ronda: ${_obs.text.trim()} - $guardia - ${DateFormat('dd/MM HH:mm').format(DateTime.now())}';
    try {
      await Share.shareXFiles(_fotos.map((f) => XFile(f)).toList(), text: msg);
    } catch (_) {}

    if (!mounted) return;
    TopToast.show(context, 'Ronda guardada');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final faltan = (_min - _fotos.length).clamp(0, _min);
    final completo = faltan == 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ronda'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(26),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  'Inicio: ${DateFormat('dd/MM HH:mm').format(_inicio)}  ·  ${AppState.instance.userNombre ?? 'Sin guardia'}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: completo ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(completo ? Icons.check_circle : Icons.photo_camera,
                    color: completo ? AppColors.verde : const Color(0xFFEF6C00), size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    completo
                        ? 'Fotos completas: ${_fotos.length}'
                        : 'Toma $_min fotos de la ronda\nLlevas ${_fotos.length} (faltan $faltan)',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
            onPressed: _tomarFotos,
            icon: const Icon(Icons.camera_alt),
            label: Text('Abrir cámara - tomar fotos (${_fotos.length}/$_min)'),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Puedes tomar varias fotos seguidas sin confirmar cada una.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (int i = 0; i < _fotos.length; i++)
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(File(_fotos[i]), width: 92, height: 92, fit: BoxFit.cover),
                    ),
                    Positioned(
                      right: 0, top: 0,
                      child: GestureDetector(
                        onTap: () => setState(() => _fotos.removeAt(i)),
                        child: Container(
                          decoration: const BoxDecoration(color: AppColors.rojo, shape: BoxShape.circle),
                          child: const Icon(Icons.close, color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          // Puntos de control (solo si el edificio los tiene configurados).
          if (_puntos.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(children: [
              const Icon(Icons.qr_code_scanner, color: Color(0xFF6A1B9A)),
              const SizedBox(width: 8),
              Text('Puntos: ${_escaneados.length}/${_puntos.length}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ]),
            const SizedBox(height: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6A1B9A), minimumSize: const Size(double.infinity, 48)),
              onPressed: _escanearPunto,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Escanear punto de control'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final pt in _puntos)
                  Chip(
                    avatar: Icon(
                      _escaneados.contains(pt['codigo']?.toString()) ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: _escaneados.contains(pt['codigo']?.toString()) ? AppColors.verde : Colors.grey,
                      size: 18,
                    ),
                    label: Text(pt['nombre']?.toString() ?? ''),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          TextField(controller: _obs, maxLines: 3,
              decoration: const InputDecoration(labelText: 'Observaciones / novedades', alignLabelWithHint: true)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: completo ? AppColors.verde : Colors.grey,
                minimumSize: const Size(double.infinity, 52)),
            onPressed: _saving ? null : _guardar,
            icon: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.save),
            label: const Text('GUARDAR RONDA'),
          ),
        ),
      ),
    );
  }
}
