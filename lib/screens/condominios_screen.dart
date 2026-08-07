import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../db/database_helper.dart';
import '../services/cloud.dart';
import '../services/pdf_export.dart';
import '../theme.dart';
import 'online_screen.dart';
import 'config_screen.dart';

/// Panel de ADMINISTRADOR por edificio: desde un solo dispositivo se puede ver
/// la actividad de cada condominio, descargarla y cambiar su configuración.
class CondominiosScreen extends StatefulWidget {
  const CondominiosScreen({super.key});
  @override
  State<CondominiosScreen> createState() => _CondominiosScreenState();
}

class _CondominiosScreenState extends State<CondominiosScreen> {
  List<Map<String, dynamic>> _edificios = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final eds = await db.query('edificios', orderBy: 'nombre');
    if (!mounted) return;
    setState(() => _edificios = eds);
  }

  Future<void> _descargar(String id, String nombre) async {
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    String? path;
    String? error;
    try {
      final eventos = await Cloud.eventos(edificio: id, limit: 1500);
      path = await PdfExport.actividadNube(eventos, nombre);
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    Navigator.pop(context); // cerrar spinner
    if (path != null) {
      try {
        await Share.shareXFiles([XFile(path)], text: 'Actividad OSIRIS - $nombre');
      } catch (_) {}
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo generar el PDF: ${error ?? ''}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Condominios')),
      body: _edificios.isEmpty
          ? const Center(child: Text('No hay edificios registrados'))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 4, 4, 10),
                  child: Text('Desde aquí gestionas cada condominio: ver su actividad, '
                      'descargar el PDF y cambiar su configuración.',
                      style: TextStyle(fontSize: 12, color: Colors.black54)),
                ),
                for (final e in _edificios)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            const CircleAvatar(
                              backgroundColor: Color(0x1A0A335D),
                              child: Icon(Icons.apartment, color: AppColors.azulMarino),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(e['nombre']?.toString() ?? '',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            ),
                          ]),
                          const SizedBox(height: 10),
                          Row(children: [
                            Expanded(
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(backgroundColor: AppColors.azulMarino),
                                onPressed: () => Navigator.push(context, MaterialPageRoute(
                                    builder: (_) => OnlineScreen(soloEdificio: false, edificioInicial: e['id'] as String))),
                                icon: const Icon(Icons.wifi_tethering, size: 18),
                                label: const Text('Ver'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(backgroundColor: AppColors.verde),
                                onPressed: () => _descargar(e['id'] as String, e['nombre']?.toString() ?? ''),
                                icon: const Icon(Icons.picture_as_pdf, size: 18),
                                label: const Text('PDF'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => Navigator.push(context, MaterialPageRoute(
                                    builder: (_) => ConfigScreen(initialEdificio: e['id'] as String))),
                                icon: const Icon(Icons.settings, size: 18),
                                label: const Text('Config'),
                              ),
                            ),
                          ]),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
