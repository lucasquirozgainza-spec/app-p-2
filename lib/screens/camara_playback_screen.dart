import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/dvr.dart';
import '../services/gallery.dart';
import '../theme.dart';

/// Reproduccion de GRABACIONES del DVR por canal y rango de fecha/hora (RTSP
/// playback de Dahua). Permite grabar/descargar el clip que se ve.
class CamaraPlaybackScreen extends StatefulWidget {
  final Map<String, dynamic> cam;
  const CamaraPlaybackScreen({super.key, required this.cam});
  @override
  State<CamaraPlaybackScreen> createState() => _CamaraPlaybackScreenState();
}

class _CamaraPlaybackScreenState extends State<CamaraPlaybackScreen> {
  VlcPlayerController? _c;
  int _canal = 1;
  DateTime _desde = DateTime.now().subtract(const Duration(hours: 1));
  DateTime _hasta = DateTime.now();
  bool _grabando = false;
  String? _dirGrab;

  Future<void> _pick(bool desde) async {
    final base = desde ? _desde : _hasta;
    final d = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime.now().subtract(const Duration(days: 90)),
      lastDate: DateTime.now(),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(base));
    if (t == null) return;
    final dt = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    setState(() => desde ? _desde = dt : _hasta = dt);
  }

  String get _url => Dvr.rtspPlayback(
        host: widget.cam['host']?.toString() ?? '',
        puerto: (widget.cam['puerto'] as int?) ?? 554,
        usuario: widget.cam['usuario']?.toString() ?? 'admin',
        clave: widget.cam['clave']?.toString() ?? '',
        canal: _canal,
        desde: _desde,
        hasta: _hasta,
      );

  Future<void> _reproducir() async {
    if (_hasta.isBefore(_desde)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('La fecha final debe ser mayor a la inicial')));
      return;
    }
    if (_c == null) {
      _c = VlcPlayerController.network(_url, hwAcc: HwAcc.full, autoPlay: true,
          options: VlcPlayerOptions(rtp: VlcRtpOptions([VlcRtpOptions.rtpOverRtsp(true)])));
    } else {
      try {
        await _c!.stop();
        await _c!.setMediaFromNetwork(_url, hwAcc: HwAcc.full, autoPlay: true);
      } catch (_) {}
    }
    setState(() {});
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
    } catch (_) {}
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  String _fmt(DateTime d) => DateFormat('dd/MM HH:mm').format(d);

  @override
  Widget build(BuildContext context) {
    final canales = (widget.cam['canales'] as int?) ?? 1;
    return Scaffold(
      appBar: AppBar(title: Text('Grabaciones · ${widget.cam['nombre'] ?? ''}')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_c != null)
            VlcPlayer(controller: _c!, aspectRatio: 16 / 9,
                placeholder: const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()))),
          const SizedBox(height: 10),
          Row(children: [
            const Text('Canal: '),
            const SizedBox(width: 8),
            DropdownButton<int>(
              value: _canal,
              items: [for (int i = 1; i <= canales; i++) DropdownMenuItem(value: i, child: Text('$i'))],
              onChanged: (v) => setState(() => _canal = v ?? 1),
            ),
          ]),
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: () => _pick(true), icon: const Icon(Icons.login, size: 18), label: Text('Desde: ${_fmt(_desde)}'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(onPressed: () => _pick(false), icon: const Icon(Icons.logout, size: 18), label: Text('Hasta: ${_fmt(_hasta)}'))),
          ]),
          const SizedBox(height: 10),
          FilledButton.icon(onPressed: _reproducir, icon: const Icon(Icons.play_arrow), label: const Text('Reproducir grabación')),
          const SizedBox(height: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _grabando ? AppColors.rojo : const Color(0xFF37474F)),
            onPressed: _c == null ? null : _grabar,
            icon: Icon(_grabando ? Icons.stop : Icons.download),
            label: Text(_grabando ? 'Detener y guardar clip' : 'Descargar / grabar clip'),
          ),
        ],
      ),
    );
  }
}
