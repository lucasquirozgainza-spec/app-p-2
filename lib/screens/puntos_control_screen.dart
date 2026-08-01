import 'package:flutter/material.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/pdf_export.dart';
import '../theme.dart';
import '../widgets/toast.dart';

/// Admin: puntos de control para rondas con QR (OPCIONAL por edificio).
/// Si un edificio no tiene puntos, la ronda funciona normal (solo fotos).
class PuntosControlScreen extends StatefulWidget {
  const PuntosControlScreen({super.key});
  @override
  State<PuntosControlScreen> createState() => _PuntosControlScreenState();
}

class _PuntosControlScreenState extends State<PuntosControlScreen> {
  List<Map<String, dynamic>> _puntos = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final rows = await db.query('puntos_control',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'id');
    if (!mounted) return;
    setState(() => _puntos = rows);
  }

  Future<void> _agregar() async {
    final nombre = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nuevo punto de control'),
        content: TextField(
          controller: nombre,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nombre (ej. Azotea, Garaje, Cisterna)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Crear')),
        ],
      ),
    );
    if (ok != true || nombre.text.trim().isEmpty) return;
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    // Codigo unico e irrepetible del punto.
    final codigo = 'OSIRIS-PC-${ed.replaceAll(' ', '')}-${DateTime.now().millisecondsSinceEpoch}';
    await db.insert('puntos_control', {
      'edificio': ed,
      'nombre': nombre.text.trim(),
      'codigo': codigo,
      'created_at': DateTime.now().toIso8601String(),
    });
    _load();
  }

  Future<void> _eliminar(Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Eliminar punto'),
        content: Text('¿Eliminar "${p['nombre']}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
              onPressed: () => Navigator.pop(context, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    final db = await DB.instance.database;
    await db.delete('puntos_control', where: 'id=?', whereArgs: [p['id']]);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Puntos de ronda (QR)'),
        actions: [
          if (_puntos.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.print),
              tooltip: 'Imprimir QRs',
              onPressed: () async {
                try {
                  await PdfExport.puntosControl(_puntos);
                } catch (_) {
                  if (mounted) TopToast.show(context, 'No se pudo generar el PDF', color: AppColors.rojo, icon: Icons.error_outline);
                }
              },
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF6A1B9A),
        icon: const Icon(Icons.add_location_alt),
        label: const Text('Agregar punto'),
        onPressed: _agregar,
      ),
      body: _puntos.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Sin puntos. Es opcional: si agregas puntos, la ronda pedirá escanear su QR. '
                    'Si no, la ronda queda solo con fotos.',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _puntos.length,
              itemBuilder: (_, i) {
                final p = _puntos[i];
                return Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                        backgroundColor: Color(0x1A6A1B9A),
                        child: Icon(Icons.qr_code_2, color: Color(0xFF6A1B9A))),
                    title: Text(p['nombre']?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: AppColors.rojo),
                      onPressed: () => _eliminar(p),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
