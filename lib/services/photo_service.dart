import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Captura fotos con la cámara y las guarda comprimidas. Devuelve la ruta.
class PhotoService {
  static final _picker = ImagePicker();

  static Future<String?> tomarFoto() async {
    final XFile? shot = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 70,
      maxWidth: 1600,
    );
    if (shot == null) return null;
    final dir = await getApplicationDocumentsDirectory();
    final fotosDir = Directory(p.join(dir.path, 'fotos'));
    if (!await fotosDir.exists()) await fotosDir.create(recursive: true);
    final name = 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final dest = p.join(fotosDir.path, name);
    await File(shot.path).copy(dest);
    return dest;
  }
}
