import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'img_util.dart';

/// Cámara NATIVA del celular (via image_picker). Es la app de cámara del
/// sistema: enfoca rápido y bien, ideal para documentos (tarjeta, carnet,
/// pasaporte). Guarda la foto en la app y en la galería. Devuelve la ruta o
/// null si el usuario canceló.
class NativeCam {
  static final ImagePicker _picker = ImagePicker();

  static Future<String?> foto({bool frontal = false, String? album}) async {
    try {
      final x = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: frontal ? CameraDevice.front : CameraDevice.rear,
      );
      if (x == null) return null;
      final dir = await getApplicationDocumentsDirectory();
      final fotosDir = Directory(p.join(dir.path, 'fotos'));
      if (!await fotosDir.exists()) await fotosDir.create(recursive: true);
      final dest = p.join(fotosDir.path, 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg');
      try {
        await File(x.path).rename(dest);
      } catch (_) {
        await File(x.path).copy(dest);
        try { await File(x.path).delete(); } catch (_) {}
      }
      // Se achica (1600 px) y se guarda en la galería por mes y tipo.
      await ImgUtil.encolar(dest, album: album);
      return dest;
    } catch (_) {
      return null;
    }
  }
}
