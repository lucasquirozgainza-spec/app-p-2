import 'dart:io';
import 'package:flutter/material.dart';
import '../services/photo_service.dart';
import '../theme.dart';

/// Campo de foto con vista previa. Captura rápida (sin pasos extra).
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

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
  }

  Future<void> _capturar() async {
    final path = await PhotoService.tomarFoto();
    if (path != null) {
      setState(() => _path = path);
      widget.onChanged(path);
    }
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
          onTap: _capturar,
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
            child: has
                ? Align(
                    alignment: Alignment.topRight,
                    child: Container(
                      margin: const EdgeInsets.all(8),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.refresh, color: Colors.white, size: 14),
                        SizedBox(width: 4),
                        Text('Repetir', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ]),
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
