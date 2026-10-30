import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../services/camara.dart';
import '../theme.dart';

/// Fotos guardadas en ESTE celular (rondas, carnets, tarjetas, turnos,
/// incidentes...) en su calidad original, ordenadas por día. Se pueden elegir
/// varias y mandar por WhatsApp. También están en la galería, en los álbumes
/// "OSIRIS Rondas", "OSIRIS Carnet", "OSIRIS Tarjetas", "OSIRIS Turnos", etc.
class MisFotosScreen extends StatefulWidget {
  const MisFotosScreen({super.key});
  @override
  State<MisFotosScreen> createState() => _MisFotosScreenState();
}

class _MisFotosScreenState extends State<MisFotosScreen> {
  List<File>? _fotos;
  final Set<String> _sel = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final d = await Camara.carpetaFotos();
    final l = <File>[];
    try {
      await for (final f in d.list()) {
        if (f is File && RegExp(r'\.(jpe?g|png|webp)$', caseSensitive: false).hasMatch(f.path) && !f.path.endsWith('_doc.jpg')) {
          l.add(f);
        }
      }
    } catch (_) {}
    l.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (mounted) setState(() => _fotos = l);
  }

  Future<void> _compartir() async {
    if (_sel.isEmpty) return;
    await Share.shareXFiles(_sel.map((p) => XFile(p)).toList());
  }

  @override
  Widget build(BuildContext context) {
    final l = _fotos;
    final grupos = <String, List<File>>{};
    final fmt = DateFormat("EEEE d 'de' MMMM", 'es');
    for (final f in l ?? const <File>[]) {
      grupos.putIfAbsent(fmt.format(f.lastModifiedSync()), () => []).add(f);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_sel.isEmpty ? 'Mis fotos' : '${_sel.length} elegida${_sel.length == 1 ? '' : 's'}'),
        actions: [
          if (_sel.isNotEmpty) IconButton(onPressed: () => setState(_sel.clear), icon: const Icon(Icons.close)),
        ],
      ),
      floatingActionButton: _sel.isEmpty
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppColors.verde,
              onPressed: _compartir,
              icon: const Icon(Icons.share),
              label: const Text('Enviar por WhatsApp'),
            ),
      body: l == null
          ? const Center(child: CircularProgressIndicator())
          : l.isEmpty
              ? const Center(child: Text('Todavía no hay fotos en este celular.'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 4, 4, 10),
                      child: Text('Toca las fotos para elegirlas y envíalas. Están en su calidad original.',
                          style: TextStyle(color: Colors.black54)),
                    ),
                    for (final g in grupos.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
                        child: Text(g.key.replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase()),
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      GridView.count(
                        crossAxisCount: 3,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
                        children: [
                          for (final f in g.value)
                            GestureDetector(
                              onTap: () => setState(() => _sel.contains(f.path) ? _sel.remove(f.path) : _sel.add(f.path)),
                              child: Stack(fit: StackFit.expand, children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.file(f, fit: BoxFit.cover, cacheWidth: 300,
                                      errorBuilder: (_, __, ___) => Container(color: Colors.black12)),
                                ),
                                if (_sel.contains(f.path))
                                  Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: AppColors.verde, width: 3),
                                      color: Colors.black26,
                                    ),
                                    child: const Align(
                                      alignment: Alignment.topRight,
                                      child: Padding(padding: EdgeInsets.all(4), child: Icon(Icons.check_circle, color: Colors.white)),
                                    ),
                                  ),
                                Positioned(
                                  left: 4,
                                  bottom: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                                    child: Text(DateFormat('HH:mm').format(f.lastModifiedSync()),
                                        style: const TextStyle(color: Colors.white, fontSize: 11)),
                                  ),
                                ),
                              ]),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
    );
  }
}
