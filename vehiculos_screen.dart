import 'package:flutter/material.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/dvr.dart';
import '../theme.dart';

/// Vista múltiple tipo DMSS: 4, 9 o 16 cámaras a la vez, mezclando canales de
/// todos los DVR del edificio. Con paginación para ver más de las que caben.
/// Usa la sub-corriente (secundaria) para que sea fluido.
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
  final List<_Stream> _todos = [];
  final Map<int, VlcPlayerController> _ctrls = {}; // indice global -> controller
  int _cols = 2; // 2=>4, 3=>9, 4=>16
  int _pagina = 0;
  bool _cargando = true;

  int get _porPagina => _cols * _cols;
  int get _paginas => _todos.isEmpty ? 1 : ((_todos.length + _porPagina - 1) ~/ _porPagina);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final cams = await db.query('camaras',
        where: "edificio=? AND ((host IS NOT NULL AND host!='') OR (host_remoto IS NOT NULL AND host_remoto!=''))",
        whereArgs: [AppState.instance.edificioId]);
    _todos.clear();
    for (final cam in cams) {
      final canales = (cam['canales'] as int?) ?? 1;
      for (int ch = 1; ch <= canales; ch++) {
        _todos.add(_Stream(
          '${cam['nombre']} · C$ch',
          Dvr.rtspVivo(
            host: Dvr.host(cam),
            puerto: (cam['puerto'] as int?) ?? 554,
            usuario: cam['usuario']?.toString() ?? 'admin',
            clave: cam['clave']?.toString() ?? '',
            canal: ch,
            subtype: 1, // secundaria = fluida
          ),
        ));
      }
    }
    if (!mounted) return;
    setState(() => _cargando = false);
    _montarPagina();
  }

  /// Crea controllers SOLO para la página visible (para no saturar el celular).
  void _montarPagina() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _ctrls.clear();
    final inicio = _pagina * _porPagina;
    for (int i = inicio; i < inicio + _porPagina && i < _todos.length; i++) {
      _ctrls[i] = VlcPlayerController.network(
        _todos[i].url,
        hwAcc: HwAcc.full,
        autoPlay: true,
        options: VlcPlayerOptions(rtp: VlcRtpOptions([VlcRtpOptions.rtpOverRtsp(true)])),
      );
    }
    if (mounted) setState(() {});
  }

  void _setLayout(int cols) {
    _cols = cols;
    _pagina = 0;
    _montarPagina();
  }

  void _pasarPagina(int delta) {
    final nueva = (_pagina + delta).clamp(0, _paginas - 1);
    if (nueva == _pagina) return;
    _pagina = nueva;
    _montarPagina();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inicio = _pagina * _porPagina;
    final visibles = <int>[
      for (int i = inicio; i < inicio + _porPagina && i < _todos.length; i++) i
    ];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Vista múltiple'),
        actions: [
          PopupMenuButton<int>(
            icon: const Icon(Icons.grid_view),
            tooltip: 'Diseño',
            onSelected: _setLayout,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 2, child: Text('4 cámaras (2x2)')),
              PopupMenuItem(value: 3, child: Text('9 cámaras (3x3)')),
              PopupMenuItem(value: 4, child: Text('16 cámaras (4x4)')),
            ],
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _todos.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No hay cámaras con IP/DDNS configurada.',
                        style: TextStyle(color: Colors.white70), textAlign: TextAlign.center),
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: GridView.count(
                        crossAxisCount: _cols,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          for (final i in visibles)
                            Container(
                              margin: const EdgeInsets.all(2),
                              color: Colors.black,
                              child: Stack(fit: StackFit.expand, children: [
                                if (_ctrls[i] != null)
                                  VlcPlayer(
                                    controller: _ctrls[i]!,
                                    aspectRatio: 16 / 9,
                                    placeholder: const Center(
                                        child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))),
                                  ),
                                Positioned(
                                  left: 3, bottom: 3,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                    color: Colors.black54,
                                    child: Text(_todos[i].etiqueta,
                                        style: const TextStyle(color: Colors.white, fontSize: 9)),
                                  ),
                                ),
                              ]),
                            ),
                        ],
                      ),
                    ),
                    if (_paginas > 1)
                      Container(
                        color: const Color(0xFF111318),
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(icon: const Icon(Icons.chevron_left, color: Colors.white), onPressed: () => _pasarPagina(-1)),
                            Text('Página ${_pagina + 1}/$_paginas', style: const TextStyle(color: Colors.white)),
                            IconButton(icon: const Icon(Icons.chevron_right, color: Colors.white), onPressed: () => _pasarPagina(1)),
                          ],
                        ),
                      ),
                  ],
                ),
    );
  }
}
