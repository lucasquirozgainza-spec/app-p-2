import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import '../services/camara.dart';
import '../services/img_util.dart';
import '../theme.dart';

/// Cámara de OSIRIS: disparo inmediato y fotos seguidas sin confirmar.
/// - El botón solo se bloquea mientras el sensor captura (no mientras se
///   procesa): el enderezado/galería van en una cola en segundo plano.
/// - multi=false: una foto y vuelve. multi=true: varias; "Listo" o el botón
///   atrás devuelven las fotos tomadas (no se pierden).
/// - Resolución máxima del sensor (sin recorte a 1x), salvo la selfie rápida.
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
  List<CameraDescription> _cams = [];
  int _idx = 0;
  int _gen = 0;              // evita carreras si se reinicia la cámara dos veces
  final List<String> _fotos = [];
  bool _capturando = false;  // solo mientras el sensor toma la foto
  bool _terminando = false;
  bool _destello = false;    // efecto visual del disparo
  bool _flash = false;
  String? _error;
  bool _errorPermiso = false;
  final GlobalKey _previewKey = GlobalKey();
  Offset? _focusRing;
  double _zoom = 1.0, _zoomMin = 1.0, _zoomMax = 1.0, _zoomBase = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cargarCamaras();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gen++; // cualquier inicio pendiente se descarta al terminar
    _liberar();
    super.dispose();
  }

  /// Todas las operaciones sobre la cámara (abrir / liberar) van EN FILA: dos
  /// initialize() simultáneos sobre el mismo lente, o abrir una nueva antes de
  /// que la anterior termine de liberarse, dejaban la vista previa en negro.
  Future<void> _fila = Future.value();
  Future<void> _enFila(Future<void> Function() op) {
    final f = _fila.then((_) => op()).catchError((_) {});
    _fila = f;
    return f;
  }

  /// Quita la cámara de la pantalla y la libera (en la fila).
  void _liberar() {
    final c = _controller;
    if (c == null) return;
    _controller = null;
    if (mounted) setState(() {});
    _enFila(() => c.dispose());
  }

  Future<void> _cargarCamaras() async {
    try {
      _cams = await availableCameras();
      if (_cams.isEmpty) {
        if (mounted) setState(() => _error = 'Este celular no tiene cámara disponible.');
        return;
      }
      final buscada = widget.frontal ? CameraLensDirection.front : CameraLensDirection.back;
      _idx = _cams.indexWhere((c) => c.lensDirection == buscada);
      if (_idx < 0) _idx = 0;
      await _iniciar();
    } catch (e) {
      _mostrarError(e);
    }
  }

  void _mostrarError(Object e) {
    if (!mounted) return;
    final txt = e is CameraException ? '${e.code} ${e.description ?? ''}' : '$e';
    final permiso = txt.toLowerCase().contains('denied') || txt.toLowerCase().contains('permission');
    setState(() {
      _errorPermiso = permiso;
      _error = permiso
          ? 'OSIRIS no tiene permiso para usar la cámara.'
          : 'No se pudo abrir la cámara. Cierra otras apps que la usen e intenta de nuevo.';
    });
  }

  Future<void> _iniciar() {
    if (_cams.isEmpty) return Future.value();
    final gen = ++_gen;
    _liberar();
    return _enFila(() => _abrir(gen));
  }

  Future<void> _abrir(int gen) async {
    // Pedido viejo (se cambió de cámara, se salió de la app o se cerró).
    if (!mounted || gen != _gen) return;

    final preset = widget.rapida ? ResolutionPreset.high : ResolutionPreset.max;
    final c = CameraController(_cams[_idx], preset,
        enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
    try {
      await c.initialize();
    } catch (e) {
      await c.dispose();
      if (gen == _gen) _mostrarError(e);
      return;
    }
    // Si mientras tanto se pidió otro reinicio o se cerró la pantalla, descartar.
    if (!mounted || gen != _gen) {
      await c.dispose();
      return;
    }
    _controller = c;
    _error = null;
    setState(() {});
    // Ajustes secundarios: nunca bloquean la vista previa.
    try { await c.unlockCaptureOrientation(); } catch (_) {} // horizontal queda horizontal
    try { await c.setFlashMode(_flash ? FlashMode.torch : FlashMode.off); } catch (_) {}
    try {
      _zoomMin = await c.getMinZoomLevel();
      _zoomMax = await c.getMaxZoomLevel();
      _zoom = 1.0.clamp(_zoomMin, _zoomMax).toDouble(); // 1x = lente principal, campo completo
      await c.setZoomLevel(_zoom);
    } catch (_) {}
    try { await c.setFocusMode(FocusMode.auto); } catch (_) {}
    try { await c.setExposureMode(ExposureMode.auto); } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      // Liberar la cámara SOLO al salir de la app (otra app / Ajustes). Con
      // "inactive" (bajar la cortina de notificaciones, un diálogo del
      // sistema) se liberaba en plena foto y la foto se perdía.
      _gen++; // aunque todavía no haya abierto: el inicio pendiente se descarta
      _liberar();
    } else if (state == AppLifecycleState.resumed) {
      // Al volver (por ejemplo de Ajustes tras dar el permiso), reabrir.
      if (_controller == null && _cams.isNotEmpty) {
        _error = null;
        _iniciar();
      } else if (_cams.isEmpty && _errorPermiso) {
        _error = null;
        _cargarCamaras();
      }
    }
  }

  Future<void> _voltear() async {
    if (_cams.length < 2 || _capturando) return;
    _idx = (_idx + 1) % _cams.length;
    await _iniciar();
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

  Future<void> _setZoom(double z) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    _zoom = z.clamp(_zoomMin, _zoomMax).toDouble();
    try { await c.setZoomLevel(_zoom); } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _enfocar(TapDownDetails d) async {
    final c = _controller;
    final box = _previewKey.currentContext?.findRenderObject() as RenderBox?;
    if (c == null || box == null) return;
    final o = box.globalToLocal(d.globalPosition);
    final pt = Offset((o.dx / box.size.width).clamp(0.0, 1.0), (o.dy / box.size.height).clamp(0.0, 1.0));
    setState(() => _focusRing = o);
    try {
      await c.setFocusPoint(pt);
      await c.setExposurePoint(pt);
    } catch (_) {}
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _focusRing = null);
    });
  }

  /// Disparo: el botón solo espera al SENSOR. Mover el archivo es instantáneo
  /// y el enderezado queda en la cola de fondo.
  Future<void> _tomar() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _capturando || _terminando) return;
    if (c.value.isTakingPicture) return;
    setState(() { _capturando = true; _destello = true; });
    Future.delayed(const Duration(milliseconds: 90), () {
      if (mounted) setState(() => _destello = false);
    });
    try {
      final XFile shot = await c.takePicture();
      final dest = await Camara.moverAFotos(shot.path);
      _fotos.add(dest);
      ImgUtil.encolar(dest, album: widget.album);
      final completo = !widget.multi || (widget.minFotos > 0 && _fotos.length >= widget.minFotos);
      if (completo) {
        _capturando = false;
        await _terminar();
        return;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo tomar la foto. Intenta de nuevo.')));
      }
    }
    if (mounted) setState(() => _capturando = false);
  }

  /// Cierra devolviendo las fotos. Espera la cola (normalmente ya terminó)
  /// para que quien las use (WhatsApp, OCR, nube) reciba fotos derechas.
  Future<void> _terminar() async {
    if (_terminando) return;
    if (_fotos.isEmpty) {
      if (mounted) Navigator.pop(context);
      return;
    }
    if (!mounted) return;
    setState(() => _terminando = true);
    await ImgUtil.esperarPendientes();
    if (mounted) Navigator.pop(context, List<String>.from(_fotos));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<List<String>>(
      // Con fotos tomadas, "atrás" = Listo (no se pierden las fotos).
      canPop: _fotos.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _terminar();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(
            widget.multi
                ? '${_fotos.length}${widget.minFotos > 0 ? ' / ${widget.minFotos}' : ''} foto${_fotos.length == 1 ? '' : 's'}'
                : 'Foto',
            style: const TextStyle(color: Colors.white),
          ),
          actions: [
            if (_controller != null)
              IconButton(
                icon: Icon(_flash ? Icons.flash_on : Icons.flash_off),
                tooltip: 'Linterna',
                onPressed: _toggleFlash,
              ),
            if (_cams.length > 1 && _controller != null)
              IconButton(
                icon: const Icon(Icons.cameraswitch_outlined),
                tooltip: 'Cambiar cámara',
                onPressed: _voltear,
              ),
            if (widget.multi && _fotos.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.verde, minimumSize: const Size(0, 40)),
                  onPressed: _terminando ? null : _terminar,
                  child: const Text('Listo'),
                ),
              ),
          ],
        ),
        body: _error != null ? _vistaError() : _vistaCamara(),
      ),
    );
  }

  Widget _vistaError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(_errorPermiso ? Icons.no_photography_outlined : Icons.error_outline,
              color: Colors.white70, size: 48),
          const SizedBox(height: 14),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15)),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              if (_errorPermiso) {
                await openAppSettings(); // al volver, se reabre sola (resumed)
              } else {
                setState(() => _error = null);
                _cams.isEmpty ? _cargarCamaras() : _iniciar();
              }
            },
            child: Text(_errorPermiso ? 'Abrir ajustes' : 'Reintentar'),
          ),
        ]),
      ),
    );
  }

  Widget _vistaCamara() {
    final c = _controller;
    final listo = c != null && c.value.isInitialized;
    return Stack(children: [
      Column(children: [
        Expanded(
          child: !listo
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : Center(
                  child: GestureDetector(
                    onScaleStart: (_) => _zoomBase = _zoom,
                    onScaleUpdate: (d) {
                      if (d.pointerCount < 2 || _zoomMax <= _zoomMin) return;
                      _setZoom(_zoomBase * d.scale);
                    },
                    onTapDown: _enfocar,
                    child: Stack(alignment: Alignment.bottomCenter, children: [
                      CameraPreview(c!, key: _previewKey),
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
                      if (_zoomMax > _zoomMin) Positioned(bottom: 12, child: _zoomBar()),
                    ]),
                  ),
                ),
        ),
        if (widget.multi && _fotos.isNotEmpty) _tira(),
        _barraDisparo(listo),
      ]),
      // Destello breve al disparar (confirma que la foto se tomó).
      IgnorePointer(
        child: AnimatedOpacity(
          opacity: _destello ? 0.55 : 0,
          duration: const Duration(milliseconds: 80),
          child: Container(color: Colors.white),
        ),
      ),
      if (_terminando)
        Container(
          color: Colors.black54,
          alignment: Alignment.center,
          child: const Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 12),
            Text('Guardando fotos…', style: TextStyle(color: Colors.white)),
          ]),
        ),
    ]);
  }

  Widget _zoomBar() {
    Widget b(String label, double z) {
      final activo = (_zoom - z).abs() < 0.15;
      return GestureDetector(
        onTap: () => _setZoom(z),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          width: 34, height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: activo ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Text(label,
              style: TextStyle(color: activo ? Colors.black : Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(16)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        b('1x', 1.0.clamp(_zoomMin, _zoomMax).toDouble()),
        if (_zoomMax >= 2) b('2x', 2.0),
        if (_zoomMax > 2.2) b('${_zoomMax.floor()}x', _zoomMax),
      ]),
    );
  }

  Widget _tira() {
    return Container(
      height: 64,
      color: Colors.black,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        itemCount: _fotos.length,
        itemBuilder: (_, i) {
          final f = _fotos[_fotos.length - 1 - i];
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              // cacheWidth: miniatura liviana (no carga la foto de 12 MP entera).
              child: Image.file(File(f), width: 52, height: 52, fit: BoxFit.cover, cacheWidth: 120,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => Container(width: 52, height: 52, color: Colors.white10)),
            ),
          );
        },
      ),
    );
  }

  Widget _barraDisparo(bool listo) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 22),
      child: SafeArea(
        top: false,
        child: Center(
          child: GestureDetector(
            onTap: listo ? _tomar : null,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 80),
              opacity: (!listo || _capturando) ? 0.5 : 1,
              child: Container(
                width: 74, height: 74,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(color: AppColors.rojo, width: 5),
                ),
                child: const Icon(Icons.camera_alt, color: AppColors.rojo, size: 30),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
