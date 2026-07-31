import 'dart:io';
import 'package:image/image.dart' as img;

class UniformeResultado {
  final bool ok;         // true si detecto camisa roja o chaleco negro
  final double rojo;     // fraccion de pixeles rojos (0..1)
  final double negro;    // fraccion de pixeles oscuros (0..1)
  UniformeResultado(this.ok, this.rojo, this.negro);
}

/// Revisa la foto del guardia para estimar si lleva uniforme:
/// camisa ROJA o chaleco NEGRO en la zona del torso.
/// Es una ayuda visual (best-effort), no un juicio infalible.
class UniformeCheck {
  static Future<UniformeResultado> revisar(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final full = img.decodeImage(bytes);
      if (full == null) return UniformeResultado(true, 0, 0); // no se pudo leer: no molestar
      // Reducir para acelerar el analisis.
      final im = img.copyResize(full, width: 200);
      final w = im.width, h = im.height;
      // Zona del torso: centro-horizontal, mitad-inferior de la imagen.
      final x0 = (w * 0.22).round(), x1 = (w * 0.78).round();
      final y0 = (h * 0.45).round(), y1 = (h * 0.92).round();
      int total = 0, rojos = 0, negros = 0;
      for (int y = y0; y < y1; y += 2) {
        for (int x = x0; x < x1; x += 2) {
          final px = im.getPixel(x, y);
          final r = px.r.toDouble(), g = px.g.toDouble(), b = px.b.toDouble();
          total++;
          // Rojo: canal rojo alto y dominante sobre verde/azul.
          if (r > 100 && r > g * 1.5 && r > b * 1.5) rojos++;
          // Negro / muy oscuro (chaleco).
          if (r < 70 && g < 70 && b < 70) negros++;
        }
      }
      if (total == 0) return UniformeResultado(true, 0, 0);
      final fr = rojos / total, fn = negros / total;
      // Regla: el pecho DEBE tener al menos 10% de ROJO (camisa del uniforme).
      // Una polera negra u otro color sin rojo se marca como SIN uniforme.
      // (No se puede distinguir un chaleco negro de una polera negra solo por
      //  color, por eso se exige el rojo.)
      final ok = fr >= 0.10;
      return UniformeResultado(ok, fr, fn);
    } catch (_) {
      return UniformeResultado(true, 0, 0); // ante cualquier error, no bloquear
    }
  }
}
