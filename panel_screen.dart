import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../theme.dart';

/// Normativas: cargar y ver PDF o imágenes (reglamentos, manuales, mapas...).
class NormativasScreen extends StatefulWidget {
  const NormativasScreen({super.key});
  @override
  State<NormativasScreen> createState() => _NormativasScreenState();
}

class _NormativasScreenState extends State<NormativasScreen> {
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final rows = await db.query('normativas',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'nombre');
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  bool _esImagen(String path) {
    final e = path.toLowerCase();
    return e.endsWith('.jpg') || e.endsWith('.jpeg') || e.endsWith('.png');
  }

  Future<void> _cargar() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
    );
    if (res == null || res.files.single.path == null) return;
    final origen = res.files.single.path!;
    final nombreCtrl = TextEditingController(text: p.basenameWithoutExtension(origen));
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nombre del documento'),
        content: TextField(controller: nombreCtrl, decoration: const InputDecoration(labelText: 'Nombre')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true) return;
    final dir = await getApplicationDocumentsDirectory();
    final docsDir = Directory(p.join(dir.path, 'normativas'));
    if (!await docsDir.exists()) await docsDir.create(recursive: true);
    final dest = p.join(docsDir.path, '${DateTime.now().millisecondsSinceEpoch}${p.extension(origen)}');
    await File(origen).copy(dest);
    final db = await DB.instance.database;
    final id = await db.insert('normativas', {
      'edificio': AppState.instance.edificioId,
      'nombre': nombreCtrl.text.trim().isEmpty ? 'Documento' : nombreCtrl.text.trim(),
      'pdf_path': dest,
    });
    await Audit.log('CREAR', 'normativas', '$id');
    _load();
  }

  Future<void> _eliminar(Map<String, dynamic> n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_forever, color: AppColors.rojo, size: 36),
        title: const Text('Eliminar documento'),
        content: Text('¿Eliminar "${n['nombre'] ?? ''}"? Esta acción no se puede deshacer.'),
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
    await db.delete('normativas', where: 'id=?', whereArgs: [n['id']]);
    // Borrar tambien el archivo del documento.
    try {
      final path = n['pdf_path']?.toString() ?? '';
      if (path.isNotEmpty && File(path).existsSync()) await File(path).delete();
    } catch (_) {}
    await Audit.log('ELIMINAR', 'normativas', '${n['id']}');
    _load();
  }

  Future<void> _abrir(Map<String, dynamic> n) async {
    final path = n['pdf_path']?.toString() ?? '';
    if (path.isEmpty || !File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Archivo no disponible')));
      return;
    }
    if (_esImagen(path)) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => Dialog(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppBar(title: Text(n['nombre']?.toString() ?? ''), automaticallyImplyLeading: false, actions: [
                IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
              ]),
              Flexible(child: InteractiveViewer(child: Image.file(File(path)))),
            ],
          ),
        ),
      );
    } else {
      await OpenFilex.open(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Normativas')),
      floatingActionButton: AppState.instance.isAdmin
          ? FloatingActionButton.extended(
              backgroundColor: const Color(0xFF37474F),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.upload_file),
              label: const Text('Cargar PDF/Imagen'),
              onPressed: _cargar,
            )
          : null,
      body: _rows.isEmpty
          ? const Center(child: Text('Sin documentos. El admin puede cargar PDF o imagenes.'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length,
              itemBuilder: (_, i) {
                final n = _rows[i];
                final path = n['pdf_path']?.toString() ?? '';
                final tieneArchivo = path.isNotEmpty && File(path).existsSync();
                final img = tieneArchivo && _esImagen(path);
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(0x1A37474F),
                      child: Icon(img ? Icons.image : Icons.picture_as_pdf, color: const Color(0xFF37474F)),
                    ),
                    title: Text(n['nombre']?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(tieneArchivo ? (img ? 'Imagen' : 'PDF') : 'Sin archivo (documento de ejemplo)'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (AppState.instance.isAdmin)
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: AppColors.rojo),
                            tooltip: 'Eliminar',
                            onPressed: () => _eliminar(n),
                          ),
                        if (tieneArchivo) const Icon(Icons.open_in_new),
                      ],
                    ),
                    onTap: tieneArchivo ? () => _abrir(n) : null,
                  ),
                );
              },
            ),
    );
  }
}
