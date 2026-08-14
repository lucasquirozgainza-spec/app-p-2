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
      case 'tarjeta_turno':
        return Icons.badge;
      case 'sos':
        return Icons.sos;
      case 'tarde':
        return Icons.schedule;
      case 'ronda_saltada':
        return Icons.directions_walk;
      case 'ronda_tarde':
        return Icons.running_with_errors;
      default:
        return Icons.warning_amber;
    }
  }

  Color _color(String? tipo) {
    switch (tipo) {
      case 'uniforme':
        return const Color(0xFF6A1B9A);
      case 'tarjeta':
      case 'tarjeta_turno':
        return const Color(0xFFEF6C00);
      case 'sos':
        return AppColors.rojo;
      case 'tarde':
        return const Color(0xFFEF6C00);
      case 'ronda_saltada':
        return AppColors.rojo;
      case 'ronda_tarde':
        return const Color(0xFFF9A825);
      default:
        return const Color(0xFF283593);
    }
  }

  void _detalle(Map<String, dynamic> a) {
    final fecha = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(a['created_at'] as String));
    final foto = a['foto']?.toString() ?? '';
    final tieneFoto = foto.isNotEmpty && File(foto).existsSync();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        icon: Icon(_icono(a['tipo']?.toString()), color: _color(a['tipo']?.toString()), size: 38),
        title: Text('${a['guardia_nombre'] ?? ''}'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (tieneFoto)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GestureDetector(
                  onTap: () => showDialog(context: context, builder: (_) => Dialog(child: InteractiveViewer(child: Image.file(File(foto))))),
                  child: ClipRRect(borderRadius: BorderRadius.circular(10),
                      child: Image.file(File(foto), height: 180, width: double.infinity, fit: BoxFit.cover)),
                ),
              ),
            Text(a['mensaje']?.toString() ?? '', style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 10),
            Text('Tipo: ${a['tipo'] ?? 'general'}', style: const TextStyle(color: Colors.black54, fontSize: 12)),
            Text('Fecha: $fecha', style: const TextStyle(color: Colors.black54, fontSize: 12)),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
      ),
    );
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
                final color = _color(a['tipo']?.toString());
                return Card(
                  child: ListTile(
                    onTap: () => _detalle(a),
                    leading: tieneFoto
                        ? CircleAvatar(backgroundImage: FileImage(File(foto)))
                        : CircleAvatar(
                            backgroundColor: color.withOpacity(.15),
                            child: Icon(_icono(a['tipo']?.toString()), color: color)),
                    title: Text(a['mensaje']?.toString() ?? '',
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${a['guardia_nombre'] ?? ''} · $fecha'),
                    trailing: const Icon(Icons.chevron_right, color: Colors.black26),
                  ),
                );
              },
            ),
    );
  }
}
