import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'blur_util.dart';

class PhotoResult {
  final String path;
  final double sharpness;
  bool get borrosa => sharpness < kBlurThreshold;
  PhotoResult(this.path, this.sharpness);
}

/// Captura fotos con la camara, las guarda comprimidas y evalua si estan
/// borrosas.
class PhotoService {
  static final _picker = ImagePicker();

  static Future<PhotoResult?> tomarFoto() async {
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
    final score = await sharpnessScore(dest);
    return PhotoResult(dest, score);
  }
}
