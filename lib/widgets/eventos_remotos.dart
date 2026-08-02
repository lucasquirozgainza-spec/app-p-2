import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/app_state.dart';
import '../services/cloud.dart';
import '../theme.dart';

/// Muestra los registros de OTROS equipos (celulares) del mismo edificio, en
/// línea desde la nube. Así el historial se comparte entre los guardias del
/// edificio (bloque A ve lo del bloque B, etc.).
class EventosRemotos extends StatefulWidget {
  final String tipo; // 'Visita', 'Ronda', 'Encomienda'...
  final IconData icon;
  final Color color;
  final List<String> tituloKeys; // claves del detalle para el titulo
  const EventosRemotos({
    super.key,
    required this.tipo,
    required this.icon,
    required this.color,
    required this.tituloKeys,
  });

  @override
  State<EventosRemotos> createState() => _EventosRemotosState();
}

class _EventosRemotosState extends State<EventosRemotos> {
  List<Map<String, dynamic>> _rows = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final evs = await Cloud.eventos(tipo: widget.tipo, edificio: AppState.instance.edificioId, limit: 60);
    final otros = evs.where((e) => e['device_id']?.toString() != Cloud.deviceId).toList();
    if (!mounted) return;
    setState(() {
      _rows = otros;
      _cargando = false;
    });
  }

  Map _detalle(Map<String, dynamic> e) {
    final d = e['detalle'];
    if (d is Map) return d;
    return {};
  }

  /// Lista de URLs de fotos del evento (foto_url o fotos_url).
  List<String> _fotos(Map<String, dynamic> e) {
    final d = _detalle(e);
    final urls = <String>[];
    final una = d['foto_url'];
    if (una is String && una.isNotEmpty) urls.add(una);
    final varias = d['fotos_url'];
    if (varias is List) {
      for (final u in varias) {
        if (u is String && u.isNotEmpty) urls.add(u);
      }
    }
    return urls;
  }

  String _hora(String? iso) {
    try {
      return DateFormat('dd/MM HH:mm').format(DateTime.parse(iso!).toLocal());
    } catch (_) {
      return '';
    }
  }

  void _abrir(Map<String, dynamic> e) {
    final d = _detalle(e);
    final fotos = _fotos(e);
    const ocultas = {'ubicacion', 'foto_url', 'fotos_url'};
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        icon: Icon(widget.icon, color: widget.color, size: 36),
        title: Text('${widget.tipo} · otro equipo'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Guardia: ${e['guardia'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Fecha: ${_hora(e['created_at']?.toString())}', style: const TextStyle(color: Colors.black54, fontSize: 12)),
            const SizedBox(height: 8),
            for (final entry in d.entries)
              if ('${entry.value}'.trim().isNotEmpty && !ocultas.contains(entry.key))
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text('${entry.key}: ${entry.value}'),
                ),
            if (fotos.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('Fotos', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0277BD))),
              const SizedBox(height: 6),
              for (final u in fotos)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(u, fit: BoxFit.contain,
                        loadingBuilder: (c, w, p) => p == null
                            ? w
                            : const SizedBox(height: 120, child: Center(child: CircularProgressIndicator())),
                        errorBuilder: (_, __, ___) => const SizedBox(
                            height: 60, child: Center(child: Text('No se pudo cargar la foto')))),
                  ),
                ),
            ],
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando || _rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.wifi_tethering, color: Color(0xFF0277BD), size: 18),
          const SizedBox(width: 6),
          Text('De otros equipos del edificio (${_rows.length})',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0277BD))),
        ]),
        const SizedBox(height: 6),
        for (final e in _rows)
          Card(
            color: const Color(0xFFF3F8FC),
            child: ListTile(
              onTap: () => _abrir(e),
              leading: _fotos(e).isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(_fotos(e).first,
                          width: 44, height: 44, fit: BoxFit.cover, cacheWidth: 120,
                          errorBuilder: (_, __, ___) => CircleAvatar(
                              backgroundColor: widget.color.withOpacity(.15),
                              child: Icon(widget.icon, color: widget.color, size: 20))),
                    )
                  : CircleAvatar(backgroundColor: widget.color.withOpacity(.15), child: Icon(widget.icon, color: widget.color, size: 20)),
              title: Text(
                widget.tituloKeys.map((k) => _detalle(e)[k]?.toString() ?? '').where((v) => v.isNotEmpty).join(' · '),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('${e['guardia'] ?? ''} · ${_hora(e['created_at']?.toString())}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right, color: Colors.black26),
            ),
          ),
      ],
    );
  }
}
