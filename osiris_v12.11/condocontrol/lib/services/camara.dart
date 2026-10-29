import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    // Rondas: cámara con el procesamiento del FABRICANTE (HDR / automático).
    bool procesada = false,
    // Carnets, placas, tarjetas: además de la original, una copia LEGIBLE
    // (derecha, con más contraste y nitidez) hecha en segundo plano.
    bool documento = false,
  }) async {
    // Un doble toque abría dos cámaras (dos controladores sobre el mismo lente
    // o "already_active" en la nativa) y dos pedidos de permiso a la vez.
    if (_abierta) return null;
    _abierta = true;
    try {
      if (!await Permisos.camara(context)) return null;
      if (!context.mounted) return null;
      if (AppState.instance.camaraNativa) {
        return _despues(
            await _nativa(context, multi: multi, minFotos: minFotos, frontal: frontal, album: album), documento);
      }
      if (procesada && !_proFalla && Platform.isAndroid) {
        try {
          return _despues(
              await _procesada(multi: multi, minFotos: minFotos, frontal: frontal, album: album), documento);
        } on MissingPluginException {
          _proFalla = true; // versión sin la cámara procesada: la de siempre
        } on PlatformException catch (e) {
          if (e.code == 'ocupada') return null;
          _proFalla = true; // este celular no pudo abrirla: la de siempre
        }
        if (!context.mounted) return null;
      }
      return _despues(
          await Navigator.push<List<String>>(
            context,
            MaterialPageRoute(
              builder: (_) => CameraScreen(
                  multi: multi, minFotos: minFotos, frontal: frontal, album: album, rapida: rapida),
            ),
          ),
          documento);
    } finally {
      _abierta = false;
    }
  }

  static bool _abierta = false;
  static bool _proFalla = false;
  static const _canal = MethodChannel('osiris/camara_pro');

  /// Documentos: la copia legible se arma en segundo plano (la foto queda
  /// lista al instante).
  static List<String>? _despues(List<String>? fotos, bool documento) {
    if (documento && fotos != null) {
      for (final f in fotos) {
        ImgUtil.encolarDocumento(f);
      }
    }
    return fotos;
  }

  /// Cámara procesada (código Android propio): procesamiento del fabricante
  /// cuando el celular lo tiene; si no, resolución y calidad máximas.
  static Future<List<String>?> _procesada({
    required bool multi,
    required int minFotos,
    required bool frontal,
    String? album,
  }) async {
    final dir = await carpetaFotos();
    final r = await _canal.invokeMethod<List<Object?>>('tomar', {
      'multi': multi,
      'minFotos': minFotos,
      'frontal': frontal,
      'dir': dir.path,
    });
    if (r == null) return null;
    final fotos = [for (final x in r) if (x != null && '$x'.isNotEmpty) '$x'];
    for (final f in fotos) {
      ImgUtil.encolar(f, album: album); // copia a la galería
    }
    return fotos.isEmpty ? null : fotos;
  }

  /// Si Android cerró OSIRIS mientras estaba abierta la cámara nativa (poca
  /// memoria), la foto sólo se recupera con retrieveLostData. La guardamos en
  /// fotos/ y en la galería para que no se pierda. Devuelve cuántas recuperó.
  static Future<int> recuperarPerdidas() async {
    try {
      final lost = await _picker.retrieveLostData();
      if (lost.isEmpty) return 0;
      final files = lost.files ?? (lost.file != null ? [lost.file!] : const <XFile>[]);
      int n = 0;
      for (final f in files) {
        try {
          if (!await File(f.path).exists()) continue;
          final d = await moverAFotos(f.path);
          ImgUtil.encolar(d, album: 'OSIRIS');
          n++;
        } catch (_) {}
      }
      return n;
    } catch (_) {
      return 0;
    }
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
