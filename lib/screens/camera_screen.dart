import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../services/gallery.dart';
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
  const CameraScreen({super.key, this.multi = false, this.minFotos = 0, this.frontal = false, this.album});

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
  String? _error;

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
      // ResolutionPreset.high (720p) enfoca mas rapido y sale nitido para OCR.
      final c = CameraController(_cams[_idx], ResolutionPreset.high,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      _controller = c;
      _initFuture = c.initialize();
      await _initFuture;
      // Enfoque y exposicion automaticos continuos: agiliza y enfoca numeros/letras.
      try { await c.setFocusMode(FocusMode.auto); } catch (_) {}
      try { await c.setExposureMode(ExposureMode.auto); } catch (_) {}
      if (mounted) setState(() {});
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
      // Dar un instante al autoenfoque para que la tarjeta/carnet salga nitido.
      try {
        await c.setFocusMode(FocusMode.auto);
        await Future.delayed(const Duration(milliseconds: 600));
      } catch (_) {}
      final XFile shot = await c.takePicture();
      final dir = await getApplicationDocumentsDirectory();
      final fotosDir = Directory(p.join(dir.path, 'fotos'));
      if (!await fotosDir.exists()) await fotosDir.create(recursive: true);
      final dest = p.join(fotosDir.path, 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(shot.path).copy(dest);
      _fotos.add(dest);
      // Guardar tambien en la galeria del telefono, en su album con nombre.
      await Gallery.guardar(dest, album: widget.album);
      if (!widget.multi) {
        if (mounted) Navigator.pop(context, _fotos);
        return;
      }
      // En modo multi: al llegar al mínimo requerido, se cierra solo.
      if (widget.minFotos > 0 && _fotos.length >= widget.minFotos) {
        if (mounted) Navigator.pop(context, _fotos);
        return;
      }
      if (mounted) setState(() => _capturando = false);
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
                      // Tocar sobre el numero/letra para enfocar ahi.
                      onTapDown: (d) async {
                        try {
                          final box = context.findRenderObject() as RenderBox?;
                          if (box == null) return;
                          final o = box.globalToLocal(d.globalPosition);
                          final p = Offset(o.dx / box.size.width, o.dy / box.size.height);
                          await c.setFocusPoint(p);
                          await c.setExposurePoint(p);
                        } catch (_) {}
                      },
                      child: CameraPreview(c),
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
