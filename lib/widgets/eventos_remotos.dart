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

  String _hora(String? iso) {
    try {
      return DateFormat('dd/MM HH:mm').format(DateTime.parse(iso!).toLocal());
    } catch (_) {
      return '';
    }
  }

  void _abrir(Map<String, dynamic> e) {
    final d = _detalle(e);
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
              if ('${entry.value}'.trim().isNotEmpty && entry.key != 'ubicacion')
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text('${entry.key}: ${entry.value}'),
                ),
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
              leading: CircleAvatar(backgroundColor: widget.color.withOpacity(.15), child: Icon(widget.icon, color: widget.color, size: 20)),
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
