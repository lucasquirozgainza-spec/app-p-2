import 'package:flutter/material.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/contact_launch.dart';
import '../theme.dart';
import '../widgets/toast.dart';

class ContactosScreen extends StatefulWidget {
  const ContactosScreen({super.key});
  @override
  State<ContactosScreen> createState() => _ContactosScreenState();
}

class _ContactosScreenState extends State<ContactosScreen> {
  List<Map<String, dynamic>> _rows = [];

  // Paleta para que cada contacto tenga su color y el guardia lo identifique.
  static const _colores = [
    Color(0xFF1565C0), Color(0xFF2E7D32), Color(0xFFEF6C00), Color(0xFF6A1B9A),
    Color(0xFF00838F), Color(0xFFC62828), Color(0xFF5D4037), Color(0xFF283593),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final rows = await db.query('contactos',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'nombre');
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  Color _color(int i) => _colores[i % _colores.length];

  Future<void> _editar({Map<String, dynamic>? existente}) async {
    final nombre = TextEditingController(text: existente?['nombre']?.toString() ?? '');
    final tel = TextEditingController(text: existente?['telefono']?.toString() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(existente == null ? 'Nuevo contacto' : 'Editar contacto'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nombre, decoration: const InputDecoration(labelText: 'Nombre (ej. Saguapac, Bomberos)')),
          const SizedBox(height: 8),
          TextField(controller: tel, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Teléfono')),
        ]),
        actions: [
          if (existente != null)
            TextButton(
              onPressed: () async {
                final db = await DB.instance.database;
                await db.delete('contactos', where: 'id=?', whereArgs: [existente['id']]);
                if (context.mounted) Navigator.pop(context, true);
              },
              child: const Text('Eliminar', style: TextStyle(color: AppColors.rojo)),
            ),
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true) return;
    if (nombre.text.trim().isNotEmpty || tel.text.trim().isNotEmpty) {
      final db = await DB.instance.database;
      final datos = {
        'edificio': AppState.instance.edificioId,
        'nombre': nombre.text.trim(),
        'telefono': tel.text.trim(),
      };
      if (existente == null) {
        await db.insert('contactos', datos);
      } else {
        await db.update('contactos', datos, where: 'id=?', whereArgs: [existente['id']]);
      }
    }
    if (mounted) TopToast.show(context, 'Contactos actualizados');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Contactos')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.azulMarino,
        icon: const Icon(Icons.person_add),
        label: const Text('Agregar'),
        onPressed: () => _editar(),
      ),
      body: _rows.isEmpty
          ? const Center(child: Text('Sin contactos. Toca "Agregar".'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length,
              itemBuilder: (_, i) {
                final c = _rows[i];
                final tel = c['telefono']?.toString() ?? '';
                final nombre = c['nombre']?.toString() ?? '';
                final ini = nombre.trim().isNotEmpty ? nombre.trim()[0].toUpperCase() : '?';
                return Card(
                  child: ListTile(
                    onTap: () => _editar(existente: c),
                    leading: CircleAvatar(
                      backgroundColor: _color(i),
                      child: Text(ini, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                    title: Text(nombre, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: tel.isNotEmpty ? Text(tel) : const Text('Sin teléfono'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (tel.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.chat, color: AppColors.verde),
                          tooltip: 'WhatsApp',
                          onPressed: () => Contacto.whatsapp(context, tel),
                        ),
                      if (tel.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.call, color: AppColors.azulMarino),
                          tooltip: 'Llamar',
                          onPressed: () => Contacto.llamar(context, tel),
                        ),
                      const Icon(Icons.edit, color: Colors.black26, size: 18),
                    ]),
                  ),
                );
              },
            ),
    );
  }
}
