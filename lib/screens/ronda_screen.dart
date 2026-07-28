import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/photo_service.dart';
import '../theme.dart';

const int kFotosMinimas = 10;

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

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: AppColors.rojo));

  Future<void> _tomarFoto() async {
    final path = await PhotoService.tomarFoto();
    if (path != null) setState(() => _fotos.add(path));
  }

  Future<void> _guardar() async {
    if (_fotos.length < kFotosMinimas) {
      return _snack('Debes tomar al menos $kFotosMinimas fotos (llevas ${_fotos.length})');
    }
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    final id = await db.insert('rondas', {
      'guardia_id': s.userId,
      'guardia_nombre': s.userNombre,
      'puntos': jsonEncode({'fotos_ronda': _fotos}),
      'observaciones': _obs.text,
      'con_novedad': 0,
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'rondas', '$id');
    await Cloud.evento('Ronda', detalle: {'fotos': _fotos.length});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ronda guardada'), backgroundColor: AppColors.verde));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final faltan = (kFotosMinimas - _fotos.length).clamp(0, kFotosMinimas);
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
                        : 'Toma $kFotosMinimas fotos de la ronda\nLlevas ${_fotos.length} (faltan $faltan)',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _tomarFoto,
            icon: const Icon(Icons.add_a_photo),
            label: Text('Tomar foto (${_fotos.length}/$kFotosMinimas)'),
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
          const SizedBox(height: 16),
          TextField(controller: _obs, maxLines: 3,
              decoration: const InputDecoration(labelText: 'Observaciones / novedades', alignLabelWithHint: true)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: completo ? AppColors.verde : Colors.grey),
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
