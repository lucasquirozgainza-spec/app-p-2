import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../screens/camera_screen.dart';
import '../theme.dart';
import 'app_state.dart';
import 'img_util.dart';
import 'permisos.dart';

/// Punto ÚNICO para tomar fotos. Según el ajuste de ESTE celular usa:
/// - la cámara de OSIRIS (instantánea, sin confirmar cada foto), o
/// - la cámara NATIVA del teléfono (respeta sus proporciones; confirma cada foto).
/// En ambos casos: primero se verifica el permiso, y el enderezado de las fotos
/// corre en segundo plano (cola) sin trabar.
class Camara {
  static final _picker = ImagePicker();
  static Directory? _dir;

  /// Carpeta de fotos de la app (se calcula una sola vez).
  static Future<Directory> carpetaFotos() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, 'fotos'));
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  /// Nombre único para una foto nueva.
  static Future<String> nuevaRuta() async {
    final d = await carpetaFotos();
    return p.join(d.path, 'IMG_${DateTime.now().microsecondsSinceEpoch}.jpg');
  }

  /// Mueve la foto recién tomada a la carpeta de la app. Renombrar es
  /// instantáneo (mismo almacenamiento); si no se puede, se copia.
  static Future<String> moverAFotos(String origen) async {
    final dest = await nuevaRuta();
    try {
      await File(origen).rename(dest);
    } catch (_) {
      await File(origen).copy(dest);
      try { await File(origen).delete(); } catch (_) {}
    }
    return dest;
  }

  /// Devuelve las rutas de las fotos tomadas (o null si se canceló).
  static Future<List<String>?> tomar(
    BuildContext context, {
    bool multi = false,
    int minFotos = 0,
    bool frontal = false,
    String? album,
    bool rapida = false,
  }) async {
    if (!await Permisos.camara(context)) return null;
    if (!context.mounted) return null;
    if (AppState.instance.camaraNativa) {
      return _nativa(context, multi: multi, minFotos: minFotos, frontal: frontal, album: album);
    }
    return Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => CameraScreen(
            multi: multi, minFotos: minFotos, frontal: frontal, album: album, rapida: rapida),
      ),
    );
  }

  /// Cámara nativa del celular. Para varias fotos: llega al mínimo y luego
  /// pregunta si tomar otra. El procesado va en segundo plano entre foto y foto.
  static Future<List<String>?> _nativa(
    BuildContext context, {
    required bool multi,
    required int minFotos,
    required bool frontal,
    String? album,
  }) async {
    final fotos = <String>[];
    while (true) {
      XFile? x;
      try {
        x = await _picker.pickImage(
          source: ImageSource.camera,
          preferredCameraDevice: frontal ? CameraDevice.front : CameraDevice.rear,
          // Sin imageQuality ni tamaño máximo: foto ORIGINAL, sin recorte.
        );
      } catch (_) {
        // Permiso revocado mientras la app estaba abierta, u otro error.
        if (context.mounted) await Permisos.camara(context);
        break;
      }
      if (x == null) break; // canceló la cámara

      try {
        final dest = await moverAFotos(x.path);
        fotos.add(dest);
        ImgUtil.encolar(dest, album: album); // segundo plano
      } catch (_) {}

      if (!multi) break;
      if (minFotos > 0 && fotos.length < minFotos) continue;
      if (!context.mounted) break;
      final otra = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.photo_library_outlined, color: AppColors.azulMarino, size: 32),
          title: Text('${fotos.length} foto${fotos.length == 1 ? '' : 's'}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Listo')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.add_a_photo, size: 18),
              label: const Text('Otra'),
            ),
          ],
        ),
      );
      if (otra != true) break;
    }
    if (fotos.isEmpty) return null;
    // Las fotos se devuelven ya derechas (normalmente la cola ya terminó).
    await ImgUtil.esperarPendientes();
    return fotos;
  }
}
