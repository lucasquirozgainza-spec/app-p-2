import 'package:flutter/material.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/dvr.dart';
import '../theme.dart';

/// Vista múltiple: hasta 4 cámaras en una sola pantalla (2x2), pudiendo mezclar
/// canales de distintos DVR del mismo edificio (por RTSP, calidad secundaria
/// para que sea fluido).
class CamaraMultiScreen extends StatefulWidget {
  const CamaraMultiScreen({super.key});
  @override
  State<CamaraMultiScreen> createState() => _CamaraMultiScreenState();
}

class _Stream {
  final String etiqueta;
  final String url;
  _Stream(this.etiqueta, this.url);
}

class _CamaraMultiScreenState extends State<CamaraMultiScreen> {
  List<Map<String, dynamic>> _cams = [];
  final List<_Stream?> _celdas = [null, null, null, null];
  final List<VlcPlayerController?> _ctrls = [null, null, null, null];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final rows = await db.query('camaras',
        where: "edificio=? AND host IS NOT NULL AND host!=''",
        whereArgs: [AppState.instance.edificioId]);
    if (!mounted) return;
    setState(() => _cams = rows);
  }

  Future<void> _elegir(int celda) async {
    final opciones = <_Stream>[];
    for (final cam in _cams) {
      final canales = (cam['canales'] as int?) ?? 1;
      for (int ch = 1; ch <= canales; ch++) {
        opciones.add(_Stream(
          '${cam['nombre']} · Canal $ch',
          Dvr.rtspVivo(
            host: cam['host'].toString(),
            puerto: (cam['puerto'] as int?) ?? 554,
            usuario: cam['usuario']?.toString() ?? 'admin',
            clave: cam['clave']?.toString() ?? '',
            canal: ch,
            subtype: 1, // secundaria = mas fluida en vista multiple
          ),
        ));
      }
    }
    if (opciones.isEmpty) return;
    final sel = await showModalBottomSheet<_Stream>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final o in opciones)
              ListTile(
                leading: const Icon(Icons.videocam, color: AppColors.azulMarino),
                title: Text(o.etiqueta),
                onTap: () => Navigator.pop(context, o),
              ),
          ],
        ),
      ),
    );
    if (sel == null) return;
    _ctrls[celda]?.dispose();
    final c = VlcPlayerController.network(sel.url, hwAcc: HwAcc.full, autoPlay: true,
        options: VlcPlayerOptions(rtp: VlcRtpOptions([VlcRtpOptions.rtpOverRtsp(true)])));
    setState(() {
      _celdas[celda] = sel;
      _ctrls[celda] = c;
    });
  }

  void _quitar(int celda) {
    _ctrls[celda]?.dispose();
    setState(() {
      _celdas[celda] = null;
      _ctrls[celda] = null;
    });
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c?.dispose();
    }
    super.dispose();
  }

  Widget _celda(int i) {
    final s = _celdas[i];
    final c = _ctrls[i];
    if (s == null || c == null) {
      return GestureDetector(
        onTap: () => _elegir(i),
        child: Container(
          margin: const EdgeInsets.all(3),
          color: const Color(0xFF181B20),
          child: const Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.add_circle_outline, color: Colors.white54, size: 30),
              SizedBox(height: 6),
              Text('Agregar cámara', style: TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.all(3),
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          VlcPlayer(controller: c, aspectRatio: 16 / 9,
              placeholder: const Center(child: CircularProgressIndicator(color: Colors.white))),
          Positioned(
            left: 4, bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              color: Colors.black54,
              child: Text(s.etiqueta, style: const TextStyle(color: Colors.white, fontSize: 10)),
            ),
          ),
          Positioned(
            right: 0, top: 0,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 18),
              onPressed: () => _quitar(i),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Vista múltiple (2x2)')),
      body: _cams.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No hay cámaras con IP/DDNS configurada.',
                    style: TextStyle(color: Colors.white70), textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                Expanded(child: Row(children: [Expanded(child: _celda(0)), Expanded(child: _celda(1))])),
                Expanded(child: Row(children: [Expanded(child: _celda(2)), Expanded(child: _celda(3))])),
              ],
            ),
    );
  }
}
