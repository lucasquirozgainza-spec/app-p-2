import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../theme.dart';

class ContactosScreen extends StatefulWidget {
  const ContactosScreen({super.key});
  @override
  State<ContactosScreen> createState() => _ContactosScreenState();
}

class _ContactosScreenState extends State<ContactosScreen> {
  List<Map<String, dynamic>> _rows = [];

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

  Future<void> _llamar(String tel) async {
    final clean = tel.replaceAll(RegExp(r'[^0-9+]'), '');
    final uri = Uri.parse('tel:$clean');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Contactos')),
      body: _rows.isEmpty
          ? const Center(child: Text('Sin contactos'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length,
              itemBuilder: (_, i) {
                final c = _rows[i];
                final tel = c['telefono']?.toString() ?? '';
                return Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Color(0x1A0A335D),
                      child: Icon(Icons.contact_phone, color: AppColors.azulMarino),
                    ),
                    title: Text(c['nombre']?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: tel.isNotEmpty ? Text(tel) : null,
                    trailing: tel.isNotEmpty
                        ? FilledButton.icon(
                            style: FilledButton.styleFrom(
                                backgroundColor: AppColors.verde,
                                minimumSize: const Size(0, 40)),
                            onPressed: () => _llamar(tel),
                            icon: const Icon(Icons.call, size: 18),
                            label: const Text('Llamar'),
                          )
                        : null,
                  ),
                );
              },
            ),
    );
  }
}
