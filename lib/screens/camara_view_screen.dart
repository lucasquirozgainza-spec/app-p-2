import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/dvr.dart';
import '../services/gallery.dart';
import '../theme.dart';

/// Ver una camara del DVR en vivo (RTSP). Permite cambiar de canal, alternar
/// calidad y GRABAR un clip que se guarda y se puede compartir/descargar.
class CamaraViewScreen extends StatefulWidget {
  final Map<String, dynamic> cam;
  const CamaraViewScreen({super.key, required this.cam});
  @override
  State<CamaraViewScreen> createState() => _CamaraViewScreenState();
}

class _CamaraViewScreenState extends State<CamaraViewScreen> {
  VlcPlayerController? _c;
  int _canal = 1;
  int _subtype = 0; // 0 principal, 1 secundaria (mas fluida)
  bool _grabando = false;
  String? _dirGrab;

  @override
  void initState() {
    super.initState();
    _abrir();
  }

  String get _url => Dvr.rtspVivo(
        host: widget.cam['host']?.toString() ?? '',
        puerto: (widget.cam['puerto'] as int?) ?? 554,
        usuario: widget.cam['usuario']?.toString() ?? 'admin',
        clave: widget.cam['clave']?.toString() ?? '',
        canal: _canal,
        subtype: _subtype,
      );

  void _abrir() {
    _c = VlcPlayerController.network(
      _url,
      hwAcc: HwAcc.full,
      autoPlay: true,
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions([VlcAdvancedOptions.networkCaching(1500)]),
        rtp: VlcRtpOptions([VlcRtpOptions.rtpOverRtsp(true)]),
      ),
    );
  }

  Future<void> _recargar() async {
    try {
      await _c?.stop();
      await _c?.setMediaFromNetwork(_url, hwAcc: HwAcc.full, autoPlay: true);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _grabar() async {
    final c = _c;
    if (c == null) return;
    try {
      if (!_grabando) {
        final dir = await getApplicationDocumentsDirectory();
        final d = Directory(p.join(dir.path, 'grabaciones'));
        if (!await d.exists()) await d.create(recursive: true);
        _dirGrab = d.path;
        await c.startRecording(d.path);
        setState(() => _grabando = true);
      } else {
        await c.stopRecording();
        setState(() => _grabando = false);
        // Compartir el ultimo clip grabado del directorio.
        await Future.delayed(const Duration(milliseconds: 800));
        final d = Directory(_dirGrab ?? '');
        if (await d.exists()) {
          final vids = d.listSync().whereType<File>().toList()
            ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
          if (vids.isNotEmpty) {
            await Gallery.guardar(vids.first.path, album: 'OSIRIS Grabaciones');
            await Share.shareXFiles([XFile(vids.first.path)], text: 'Grabación OSIRIS');
          }
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo grabar en este equipo')));
        setState(() => _grabando = false);
      }
    }
  }

  @override
  void dispose() {
    _c?.stopRendererScanning();
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canales = (widget.cam['canales'] as int?) ?? 1;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('${widget.cam['nombre'] ?? 'Cámara'} · Canal $_canal'),
        actions: [
          IconButton(
            tooltip: _subtype == 0 ? 'Calidad alta' : 'Más fluido',
            icon: Icon(_subtype == 0 ? Icons.hd : Icons.sd),
            onPressed: () { setState(() => _subtype = _subtype == 0 ? 1 : 0); _recargar(); },
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _recargar),
        ],
      ),
      body: Column(
        children: [
          if (_c != null)
            VlcPlayer(
              controller: _c!,
              aspectRatio: 16 / 9,
              placeholder: const SizedBox(
                height: 220,
                child: Center(child: CircularProgressIndicator(color: Colors.white)),
              ),
            ),
          Container(
            color: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: _grabando ? AppColors.rojo : AppColors.azulMarino),
                  onPressed: _grabar,
                  icon: Icon(_grabando ? Icons.stop : Icons.fiber_manual_record),
                  label: Text(_grabando ? 'Detener y guardar' : 'Grabar clip'),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white24, height: 1),
          Expanded(
            child: Container(
              color: const Color(0xFF111318),
              child: GridView.count(
                crossAxisCount: 4,
                padding: const EdgeInsets.all(10),
                children: [
                  for (int ch = 1; ch <= canales; ch++)
                    GestureDetector(
                      onTap: () { setState(() => _canal = ch); _recargar(); },
                      child: Container(
                        margin: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: ch == _canal ? AppColors.azulMarino : const Color(0xFF23262E),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text('$ch', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
