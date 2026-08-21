import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../services/gallery.dart';
import '../services/img_util.dart';
import '../theme.dart';

/// Cámara propia: permite tomar fotos SEGUIDAS sin la confirmación del
/// sistema. Devuelve la lista de rutas de las fotos tomadas.
/// - multi=false: toma una foto y regresa.
/// - multi=true: toma varias; el usuario toca "Listo" al terminar.
/// - frontal=true: abre la cámara de selfie por defecto.
/// - album: nombre del álbum de galería donde también se guarda la foto.
class CameraScreen extends StatefulWidget {
  final bool multi;
  final int minFotos;
  final bool frontal;
  final String? album;
  final bool rapida; // true = 720p rápido (selfie de turno). No para documentos.
  const CameraScreen({super.key, this.multi = false, this.minFotos = 0, this.frontal = false, this.album, this.rapida = false});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void>? _initFuture;
  List<CameraDescription> _cams = [];
  int _idx = 0;
  final List<String> _fotos = [];
  bool _capturando = false;
  bool _flash = false;
  String? _error;
  final GlobalKey _previewKey = GlobalKey();
  Offset? _focusRing;        // posición del anillo de enfoque (coords locales)
  Offset _focusNorm = const Offset(0.5, 0.5); // último punto de enfoque (0..1)
  double _zoom = 1.0;        // zoom actual
  double _zoomMin = 1.0;     // zoom mínimo del lente
  double _zoomMax = 1.0;     // zoom máximo del lente
  double _zoomBase = 1.0;    // zoom al empezar el pellizco (pinch)

  Future<void> _setZoom(double z) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final nz = z.clamp(_zoomMin, _zoomMax);
    _zoom = nz;
    try { await c.setZoomLevel(nz); } catch (_) {}
    if (mounted) setState(() {});
  }

  Widget _zoomBtn(String label, double z) {
    final activo = (_zoom - z).abs() < 0.15;
    return GestureDetector(
      onTap: () => _setZoom(z),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        width: 30, height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: activo ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label,
            style: TextStyle(
              color: activo ? Colors.black : Colors.white,
              fontWeight: FontWeight.bold, fontSize: 10,
            )),
      ),
    );
  }

  Future<void> _toggleFlash() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    _flash = !_flash;
    try {
      await c.setFlashMode(_flash ? FlashMode.torch : FlashMode.off);
    } catch (_) {
      _flash = false;
    }
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cargarCamaras();
  }

  Future<void> _cargarCamaras() async {
    try {
      _cams = await availableCameras();
      if (_cams.isEmpty) {
        setState(() => _error = 'No se encontro camara');
        return;
      }
      // Empezar con la camara pedida (selfie o trasera).
      final buscada = widget.frontal ? CameraLensDirection.front : CameraLensDirection.back;
      _idx = _cams.indexWhere((c) => c.lensDirection == buscada);
      if (_idx < 0) _idx = 0;
      await _iniciar();
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo abrir la camara');
    }
  }

  Future<void> _iniciar() async {
    try {
      if (_cams.isEmpty) return;
      await _controller?.dispose();
      // max = resolución NATIVA máxima del sensor (normalmente 4:3): capta la
      // MAYOR información posible y SIN recorte a 1x (veryHigh forzaba 16:9 y
      // recortaba el campo visual). Ya no traba porque el procesado pesado se
      // quitó del disparo. Selfie de turno (rapida): 720p veloz.
      final preset = widget.rapida ? ResolutionPreset.high : ResolutionPreset.max;
      final c = CameraController(_cams[_idx], preset,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      _controller = c;
      _initFuture = c.initialize();
      await _initFuture;
      if (mounted) setState(() {});
      // NO fijar la orientación: la foto sigue cómo está FÍSICAMENTE el teléfono
      // (si la tomas horizontal, queda horizontal). El enderezado nativo después
      // "quema" esa orientación en los píxeles para que se vea igual en WhatsApp.
      try { await c.unlockCaptureOrientation(); } catch (_) {}
      try { await c.setFlashMode(_flash ? FlashMode.torch : FlashMode.off); } catch (_) {}
      // Rango de zoom del lente (para el pellizco y los botones).
      try {
        _zoomMin = await c.getMinZoomLevel();
        _zoomMax = await c.getMaxZoomLevel();
        _zoom = _zoom.clamp(_zoomMin, _zoomMax);
        await c.setZoomLevel(_zoom);
      } catch (_) {}
      // Enfoque/exposicion automaticos en segundo plano (no bloquea la apertura).
      c.setFocusMode(FocusMode.auto).catchError((_) {});
      c.setExposureMode(ExposureMode.auto).catchError((_) {});
      c.setFocusPoint(const Offset(0.5, 0.5)).catchError((_) {});
      c.setExposurePoint(const Offset(0.5, 0.5)).catchError((_) {});
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo abrir la camara');
    }
  }

  Future<void> _voltear() async {
    if (_cams.length < 2) return;
    _idx = (_idx + 1) % _cams.length;
    setState(() {});
    await _iniciar();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      c.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _iniciar();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _tomar() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _capturando) return;
    setState(() => _capturando = true);
    try {
      // Disparo INSTANTÁNEO: el enfoque es continuo (automático) mientras se ve
      // la imagen, así que al apretar se captura de una, sin esperas ni
      // confirmación. El enderezado se hace después, aparte, para que la cámara
      // quede lista para la siguiente foto de inmediato.
      final XFile shot = await c.takePicture();
      final dir = await getApplicationDocumentsDirectory();
      final fotosDir = Directory(p.join(dir.path, 'fotos'));
      if (!await fotosDir.exists()) await fotosDir.create(recursive: true);
      final dest = p.join(fotosDir.path, 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(shot.path).copy(dest);
      _fotos.add(dest);
      if (widget.multi) {
        // RONDAS/varias fotos: enderezar (nativo, rápido) y guardar en galería
        // EN SEGUNDO PLANO. El botón queda libre YA para la siguiente foto; para
        // cuando se comparte/sube (al final), ya están todas derechas.
        () async {
          await ImgUtil.normalizarNativa(dest);
          Gallery.guardar(dest, album: widget.album);
        }();
        if (widget.minFotos > 0 && _fotos.length >= widget.minFotos) {
          if (mounted) Navigator.pop(context, _fotos);
          return;
        }
        if (mounted) setState(() => _capturando = false);
        return;
      }
      // Foto ÚNICA (carnet, tarjeta): se usa de inmediato (OCR/registro), así
      // que sí esperamos el enderezado nativo — es rápido (~fracción de seg).
      await ImgUtil.normalizarNativa(dest);
      Gallery.guardar(dest, album: widget.album);
      if (mounted) Navigator.pop(context, _fotos);
    } catch (_) {
      if (mounted) setState(() => _capturando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Camara')),
        body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!))),
      );
    }
    final c = _controller;
    final listo = c != null && c.value.isInitialized;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.multi ? 'Fotos: ${_fotos.length}${widget.minFotos > 0 ? '/${widget.minFotos}' : ''}' : 'Tomar foto'),
        actions: [
          IconButton(
            icon: Icon(_flash ? Icons.flash_on : Icons.flash_off, color: Colors.white),
            tooltip: 'Linterna',
            onPressed: _toggleFlash,
          ),
          if (_cams.length > 1)
            IconButton(
              icon: const Icon(Icons.cameraswitch, color: Colors.white),
              tooltip: 'Voltear camara (selfie)',
              onPressed: _voltear,
            ),
          if (widget.multi)
            TextButton(
              onPressed: () => Navigator.pop(context, _fotos),
              child: const Text('Listo', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
        ],
      ),
      body: !listo
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : Column(
              children: [
                Expanded(
                  child: Center(
                    child: GestureDetector(
                      // Pellizcar (dos dedos) para acercar/alejar el zoom.
                      onScaleStart: (_) => _zoomBase = _zoom,
                      onScaleUpdate: (d) {
                        if (d.pointerCount < 2 || _zoomMax <= _zoomMin) return;
                        _setZoom(_zoomBase * d.scale);
                      },
                      // Tocar sobre el numero/letra para enfocar ahi.
                      onTapDown: (d) async {
                        try {
                          final box = _previewKey.currentContext?.findRenderObject() as RenderBox?;
                          if (box == null) return;
                          final o = box.globalToLocal(d.globalPosition);
                          final nx = (o.dx / box.size.width).clamp(0.0, 1.0);
                          final ny = (o.dy / box.size.height).clamp(0.0, 1.0);
                          final p = Offset(nx, ny);
                          _focusNorm = p;
                          setState(() => _focusRing = o);
                          await c.setFocusMode(FocusMode.auto);
                          await c.setFocusPoint(p);
                          await c.setExposurePoint(p);
                        } catch (_) {}
                      },
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          CameraPreview(c, key: _previewKey),
                          if (_focusRing != null)
                            Positioned(
                              left: _focusRing!.dx - 26,
                              top: _focusRing!.dy - 26,
                              child: IgnorePointer(
                                child: Container(
                                  width: 52, height: 52,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.yellowAccent, width: 2),
                                  ),
                                ),
                              ),
                            ),
                          Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text('Toca para enfocar · pellizca para zoom',
                                style: TextStyle(color: Colors.white, fontSize: 12)),
                          ),
                          if (_zoomMax > _zoomMin)
                            Positioned(
                              bottom: 54,
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black45,
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _zoomBtn('1x', 1.0),
                                    if (_zoomMax >= 2) _zoomBtn('2x', 2.0),
                                    _zoomBtn('Max', _zoomMax),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (widget.multi && _fotos.isNotEmpty)
                  Container(
                    height: 76,
                    color: Colors.black,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.all(8),
                      children: [
                        for (final f in _fotos.reversed)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.file(File(f), width: 60, height: 60, fit: BoxFit.cover),
                            ),
                          ),
                      ],
                    ),
                  ),
                Container(
                  color: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: GestureDetector(
                      onTap: _tomar,
                      child: Container(
                        width: 74, height: 74,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          border: Border.all(color: AppColors.rojo, width: 5),
                        ),
                        child: _capturando
                            ? const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(strokeWidth: 3))
                            : const Icon(Icons.camera_alt, color: AppColors.rojo, size: 32),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
