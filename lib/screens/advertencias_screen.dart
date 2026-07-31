import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/pdf_export.dart';
import '../theme.dart';

/// Historial de advertencias (tarjetas no devueltas, guardias sin uniforme, etc.).
class AdvertenciasScreen extends StatefulWidget {
  const AdvertenciasScreen({super.key});
  @override
  State<AdvertenciasScreen> createState() => _AdvertenciasScreenState();
}

class _AdvertenciasScreenState extends State<AdvertenciasScreen> {
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final rows = await db.query('advertencias',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'id DESC');
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  IconData _icono(String? tipo) {
    switch (tipo) {
      case 'uniforme':
        return Icons.checkroom;
      case 'tarjeta':
        return Icons.badge;
      default:
        return Icons.warning_amber;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Advertencias'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Descargar PDF',
            onPressed: _rows.isEmpty
                ? null
                : () async {
                    try {
                      await PdfExport.advertencias();
                    } catch (_) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('No se pudo generar el PDF')));
                      }
                    }
                  },
          ),
        ],
      ),
      body: _rows.isEmpty
          ? const Center(child: Text('Sin advertencias registradas'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length,
              itemBuilder: (_, i) {
                final a = _rows[i];
                final fecha = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(a['created_at'] as String));
                final foto = a['foto']?.toString() ?? '';
                final tieneFoto = foto.isNotEmpty && File(foto).existsSync();
                return Card(
                  child: ListTile(
                    leading: tieneFoto
                        ? GestureDetector(
                            onTap: () => showDialog(
                              context: context,
                              builder: (_) => Dialog(child: InteractiveViewer(child: Image.file(File(foto)))),
                            ),
                            child: CircleAvatar(backgroundImage: FileImage(File(foto))),
                          )
                        : CircleAvatar(
                            backgroundColor: const Color(0x1AC62828),
                            child: Icon(_icono(a['tipo']?.toString()), color: AppColors.rojo)),
                    title: Text(a['mensaje']?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${a['guardia_nombre'] ?? ''} · $fecha'),
                  ),
                );
              },
            ),
    );
  }
}
