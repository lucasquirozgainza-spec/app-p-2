import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/device_context.dart';
import '../services/photo_service.dart';
import '../theme.dart';

const _puntosDefault = [
  'Recepcion', 'Lobby', 'Ascensor', 'Escalera', 'Piscina', 'Churrasquera',
  'Gimnasio', 'Parqueo', 'Bombas', 'Sala electrica', 'Sala de maquinas',
  'Azotea', 'Depositos', 'Basura',
];

class _Punto {
  final String nombre;
  bool novedad = false; // false=verde, true=rojo
  String descripcion = '';
  List<String> fotos = [];
  _Punto(this.nombre);
}

class RondaScreen extends StatefulWidget {
  const RondaScreen({super.key});
  @override
  State<RondaScreen> createState() => _RondaScreenState();
}

class _RondaScreenState extends State<RondaScreen> {
  late final List<_Punto> _puntos;
  final _obs = TextEditingController();
  bool _saving = false;
  final _inicio = DateTime.now();

  @override
  void initState() {
    super.initState();
    _puntos = _puntosDefault.map((e) => _Punto(e)).toList();
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: AppColors.rojo));

  Future<void> _agregarFoto(_Punto p) async {
    final res = await PhotoService.tomarFoto();
    if (res != null) setState(() => p.fotos.add(res.path));
  }

  Future<void> _guardar() async {
    // Validar: puntos con novedad requieren descripcion + al menos una foto.
    for (final p in _puntos) {
      if (p.novedad) {
        if (p.descripcion.trim().isEmpty) return _snack('${p.nombre}: falta descripcion de la novedad');
        if (p.fotos.isEmpty) return _snack('${p.nombre}: la fotografia es obligatoria');
      }
    }
    setState(() => _saving = true);
    final s = AppState.instance;
    final gps = await DeviceContext.gps();
    final disp = await DeviceContext.dispositivo();
    final conNovedad = _puntos.any((p) => p.novedad);
    final puntosJson = jsonEncode(_puntos
        .map((p) => {
              'nombre': p.nombre,
              'estado': p.novedad ? 'rojo' : 'verde',
              'descripcion': p.descripcion,
              'fotos': p.fotos,
            })
        .toList());
    final db = await DB.instance.database;
    final id = await db.insert('rondas', {
      'guardia_id': s.userId,
      'guardia_nombre': s.userNombre,
      'gps_lat': gps?['lat'],
      'gps_lng': gps?['lng'],
      'dispositivo': disp,
      'puntos': puntosJson,
      'observaciones': _obs.text,
      'con_novedad': conNovedad ? 1 : 0,
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'rondas', '$id');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ronda guardada'), backgroundColor: AppColors.verde));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ronda'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Inicio: ${DateFormat('dd/MM HH:mm').format(_inicio)}  ·  ${AppState.instance.userNombre}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ),
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _puntos.length,
        itemBuilder: (_, i) => _puntoCard(_puntos[i]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.verde),
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

  Widget _puntoCard(_Punto p) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.location_on,
                    color: p.novedad ? AppColors.rojo : AppColors.verde),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(p.nombre,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
                _estadoChip(p, false),
                const SizedBox(width: 6),
                _estadoChip(p, true),
              ],
            ),
            if (p.novedad) ...[
              const SizedBox(height: 10),
              TextField(
                decoration: const InputDecoration(
                    labelText: 'Descripcion de la novedad *', isDense: true),
                maxLines: 2,
                onChanged: (v) => p.descripcion = v,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final f in p.fotos)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(File(f), width: 48, height: 48, fit: BoxFit.cover),
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: () => _agregarFoto(p),
                    icon: const Icon(Icons.add_a_photo, size: 18),
                    label: const Text('Foto *'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _estadoChip(_Punto p, bool esRojo) {
    final activo = p.novedad == esRojo;
    final color = esRojo ? AppColors.rojo : AppColors.verde;
    return GestureDetector(
      onTap: () => setState(() => p.novedad = esRojo),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: activo ? color : color.withOpacity(0.12),
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2),
        ),
        child: Icon(esRojo ? Icons.close : Icons.check,
            color: activo ? Colors.white : color, size: 20),
      ),
    );
  }
}
