import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../theme.dart';

/// Cámara propia: permite tomar fotos SEGUIDAS sin la confirmación del
/// sistema. Devuelve la lista de rutas de las fotos tomadas.
/// - multi=false: toma una foto y regresa.
/// - multi=true: toma varias; el usuario toca "Listo" al terminar.
class CameraScreen extends StatefulWidget {
  final bool multi;
  final int minFotos;
  const CameraScreen({super.key, this.multi = false, this.minFotos = 0});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void>? _initFuture;
  final List<String> _fotos = [];
  bool _capturando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _iniciar();
  }

  Future<void> _iniciar() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _error = 'No se encontro camara');
        return;
      }
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final c = CameraController(back, ResolutionPreset.high, enableAudio: false);
      _controller = c;
      _initFuture = c.initialize();
      await _initFuture;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = 'No se pudo abrir la camara');
    }
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
      final XFile shot = await c.takePicture();
      final dir = await getApplicationDocumentsDirectory();
      final fotosDir = Directory(p.join(dir.path, 'fotos'));
      if (!await fotosDir.exists()) await fotosDir.create(recursive: true);
      final dest = p.join(fotosDir.path, 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(shot.path).copy(dest);
      _fotos.add(dest);
      if (!widget.multi) {
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
                Expanded(child: Center(child: CameraPreview(c))),
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
