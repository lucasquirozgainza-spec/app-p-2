import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/cloud.dart';
import '../theme.dart';

/// Panel del administrador: ve en tiempo real (al refrescar) los guardias
/// en línea y los eventos de TODOS los celulares (ingresos, salidas, visitas,
/// rondas, incidentes).
class OnlineScreen extends StatefulWidget {
  const OnlineScreen({super.key});
  @override
  State<OnlineScreen> createState() => _OnlineScreenState();
}

class _OnlineScreenState extends State<OnlineScreen> {
  List<Map<String, dynamic>> _presencia = [];
  List<Map<String, dynamic>> _eventos = [];
  List<Map<String, dynamic>> _turnos = [];
  String? _filtro; // null = todos
  bool _loading = true;

  static const _tipos = ['Ingreso de turno', 'Salida de turno', 'Visita', 'Ronda', 'Incidente'];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _loading = true);
    final pres = await Cloud.presencia();
    final evs = await Cloud.eventos(tipo: _filtro);
    final turnos = await Cloud.eventosTurnoMes();
    if (!mounted) return;
    setState(() {
      _presencia = pres;
      _eventos = evs;
      _turnos = turnos;
      _loading = false;
    });
  }

  bool _online(Map<String, dynamic> p) {
    try {
      final ls = DateTime.parse(p['last_seen'].toString()).toUtc();
      return DateTime.now().toUtc().difference(ls).inMinutes < 5;
    } catch (_) {
      return false;
    }
  }

  String _hace(String? iso) {
    if (iso == null) return '';
    try {
      final d = DateTime.parse(iso).toLocal();
      return DateFormat('dd/MM HH:mm').format(d);
    } catch (_) {
      return '';
    }
  }

  IconData _icono(String? tipo) {
    switch (tipo) {
      case 'Visita': return Icons.badge;
      case 'Ronda': return Icons.directions_walk;
      case 'Incidente': return Icons.warning_amber;
      case 'Ingreso de turno': return Icons.login;
      case 'Salida de turno': return Icons.logout;
      default: return Icons.event_note;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Cloud.enabled) {
      return Scaffold(
        appBar: AppBar(title: const Text('En linea')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('No hay conexion a la nube en este momento.\n'
                'Verifica tu internet e intenta de nuevo.',
                textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final enLinea = _presencia.where(_online).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('En linea'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _cargar)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Row(children: [
                    const Icon(Icons.circle, color: AppColors.verde, size: 12),
                    const SizedBox(width: 6),
                    Text('Guardias en linea (${enLinea.length})',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 6),
                  if (enLinea.isEmpty)
                    const Card(child: ListTile(title: Text('Ningun guardia en linea ahora')))
                  else
                    for (final p in enLinea)
                      Card(
                        child: ListTile(
                          leading: const CircleAvatar(
                              backgroundColor: Color(0x1A2E7D32),
                              child: Icon(Icons.shield, color: AppColors.verde)),
                          title: Text(p['guardia']?.toString() ?? '—',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('${p['edificio'] ?? ''}'
                              '${p['en_turno'] == true ? ' · En turno' : ''}'),
                          trailing: Text(_hace(p['last_seen']?.toString()),
                              style: const TextStyle(fontSize: 11, color: Colors.black54)),
                        ),
                      ),
                  const SizedBox(height: 18),
                  const Text('Dias trabajados este mes (todos los edificios)',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  ..._diasTrabajados(),
                  const SizedBox(height: 18),
                  const Text('Eventos recientes',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: [
                      ChoiceChip(
                        label: const Text('Todos'),
                        selected: _filtro == null,
                        onSelected: (_) { setState(() => _filtro = null); _cargar(); },
                      ),
                      for (final t in _tipos)
                        ChoiceChip(
                          label: Text(t),
                          selected: _filtro == t,
                          onSelected: (_) { setState(() => _filtro = t); _cargar(); },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_eventos.isEmpty)
                    const Card(child: ListTile(title: Text('Sin eventos todavia')))
                  else
                    for (final e in _eventos) _eventoTile(e),
                ],
              ),
            ),
    );
  }

  List<Widget> _diasTrabajados() {
    // Agrupa por guardia: dias distintos con "Ingreso de turno" y edificios.
    final mapa = <String, Map<String, dynamic>>{};
    for (final e in _turnos) {
      if (e['tipo'] != 'Ingreso de turno') continue;
      final g = e['guardia']?.toString() ?? 'Sin nombre';
      final m = mapa.putIfAbsent(g, () => {'dias': <String>{}, 'edif': <String>{}, 'turnos': 0});
      try {
        final d = DateTime.parse(e['created_at'].toString()).toLocal();
        (m['dias'] as Set).add(DateFormat('yyyy-MM-dd').format(d));
      } catch (_) {}
      if (e['edificio'] != null) (m['edif'] as Set).add(e['edificio'].toString());
      m['turnos'] = (m['turnos'] as int) + 1;
    }
    if (mapa.isEmpty) {
      return [const Card(child: ListTile(title: Text('Sin turnos este mes')))];
    }
    final entries = mapa.entries.toList()
      ..sort((a, b) => (b.value['dias'] as Set).length.compareTo((a.value['dias'] as Set).length));
    return [
      for (final e in entries)
        Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: AppColors.azulMarino.withOpacity(.1),
              child: Text('${(e.value['dias'] as Set).length}',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.azulMarino)),
            ),
            title: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('${(e.value['dias'] as Set).length} dias · ${e.value['turnos']} turnos · '
                '${(e.value['edif'] as Set).join(", ")}'),
          ),
        ),
    ];
  }

  Widget _eventoTile(Map<String, dynamic> e) {
    final detalle = e['detalle'];
    String sub = '';
    try {
      final m = detalle is String ? jsonDecode(detalle) : detalle;
      if (m is Map) {
        sub = m.entries.where((x) => '${x.value}'.trim().isNotEmpty)
            .map((x) => '${x.value}').join(' · ');
      }
    } catch (_) {}
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppColors.azulMarino.withOpacity(.1),
          child: Icon(_icono(e['tipo']?.toString()), color: AppColors.azulMarino, size: 20),
        ),
        title: Text('${e['tipo']} · ${e['guardia'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${e['edificio'] ?? ''}${sub.isNotEmpty ? ' · $sub' : ''}',
            maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Text(_hace(e['created_at']?.toString()),
            style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ),
    );
  }
}
