import 'dart:io';
import 'package:flutter/material.dart';
import '../services/photo_service.dart';
import '../theme.dart';

/// Campo de foto obligatoria/opcional con vista previa y detección de
/// fotos borrosas (obliga a repetir).
class PhotoField extends StatefulWidget {
  final String label;
  final bool obligatoria;
  final ValueChanged<String?> onChanged;
  final String? initialPath;

  const PhotoField({
    super.key,
    required this.label,
    required this.onChanged,
    this.obligatoria = false,
    this.initialPath,
  });

  @override
  State<PhotoField> createState() => _PhotoFieldState();
}

class _PhotoFieldState extends State<PhotoField> {
  String? _path;
  bool _procesando = false;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
  }

  Future<void> _capturar() async {
    setState(() => _procesando = true);
    final res = await PhotoService.tomarFoto();
    if (!mounted) return;
    setState(() => _procesando = false);
    if (res == null) return;

    if (res.borrosa) {
      final usarIgual = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.blur_on, color: AppColors.rojo, size: 40),
          title: const Text('Foto borrosa'),
          content: const Text(
              'La foto parece borrosa o movida. Por favor tómala de nuevo, '
              'sostén firme el teléfono y espera a que enfoque.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Usar de todos modos'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, false),
              icon: const Icon(Icons.camera_alt),
              label: const Text('Repetir foto'),
            ),
          ],
        ),
      );
      if (usarIgual != true) {
        // Descartar y volver a intentar.
        await _capturar();
        return;
      }
    }

    setState(() => _path = res.path);
    widget.onChanged(res.path);
  }

  @override
  Widget build(BuildContext context) {
    final has = _path != null && File(_path!).existsSync();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(widget.label,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (widget.obligatoria)
              const Text(' *',
                  style: TextStyle(color: AppColors.rojo, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: _procesando ? null : _capturar,
          child: Container(
            height: 150,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: has ? AppColors.verde : const Color(0xFFDDE3EA),
                width: has ? 2 : 1,
              ),
              image: has
                  ? DecorationImage(image: FileImage(File(_path!)), fit: BoxFit.cover)
                  : null,
            ),
            child: _procesando
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 8),
                        Text('Revisando nitidez...',
                            style: TextStyle(color: AppColors.azulMarino)),
                      ],
                    ),
                  )
                : has
                    ? Align(
                        alignment: Alignment.topRight,
                        child: Container(
                          margin: const EdgeInsets.all(8),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.refresh, color: Colors.white, size: 14),
                              SizedBox(width: 4),
                              Text('Repetir', style: TextStyle(color: Colors.white, fontSize: 12)),
                            ],
                          ),
                        ),
                      )
                    : const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.add_a_photo_outlined, size: 36, color: AppColors.azulMarino),
                            SizedBox(height: 6),
                            Text('Tomar foto', style: TextStyle(color: AppColors.azulMarino)),
                          ],
                        ),
                      ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
