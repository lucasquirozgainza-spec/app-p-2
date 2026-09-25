import 'dart:async';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/app_state.dart';
import '../services/cloud.dart';
import '../services/pdf_export.dart';
import '../theme.dart';
import '../widgets/evento_tile.dart';

/// ACTIVIDAD DEL EDIFICIO: siempre el edificio elegido en Configuración
/// (si está LIMCO II, solo LIMCO II; si está Millennial, solo Millennial).
/// Un filtro por tipo, la lista de a poco (con "Ver más") y quién está en línea.
class OnlineScreen extends StatefulWidget {
  /// Se mantiene por compatibilidad: la pantalla SIEMPRE usa el edificio actual.
  final bool soloEdificio;
  const OnlineScreen({super.key, this.soloEdificio = true});
  @override
  State<OnlineScreen> createState() => _OnlineScreenState();
}

class _OnlineScreenState extends State<OnlineScreen> {
  List<Map<String, dynamic>> _presencia = [];
  List<Map<String, dynamic>> _eventos = [];
  String? _filtro; // null = todos
  int _limite = 40;
  bool _loading = true;
  bool _cargando = false;
  bool _pendiente = false;
  Timer? _auto;

  static const _tipos = {
    'Visita': 'Visitas',
    'Ronda': 'Rondas',
    'Incidente': 'Incidentes',
    'Ingreso de turno': 'Ingresos de turno',
    'Salida de turno': 'Salidas de turno',
    'Encomienda': 'Encomiendas',
    'Hospedaje': 'Hospedajes',
    'Advertencia': 'Advertencias',
  };
  static const _internos = <String>{'Config', 'AdminPass', 'Guardia', 'GuardiaBaja', 'Corrección de turno', 'Prueba de conexión'};

  String get _ed => AppState.instance.edificioId;

  @override
  void initState() {
    super.initState();
    _cargar();
    _auto = Timer.periodic(const Duration(seconds: 30), (_) => _cargar(silencioso: true));
  }

  @override
  void dispose() {
    _auto?.cancel();
    super.dispose();
  }

  Future<void> _cargar({bool silencioso = false}) async {
    if (_cargando) {
      if (!silencioso) _pendiente = true;
      return;
    }
    _cargando = true;
    final tipo = _filtro, limite = _limite, ed = _ed;
    if (!silencioso && mounted) setState(() => _loading = _eventos.isEmpty);
    try {
      final res = await Future.wait([
        Cloud.presencia(edificio: ed),
        Cloud.eventos(tipo: tipo, edificio: ed, limit: limite),
      ]);
      final evs = res[1]..removeWhere((e) => _internos.contains(e['tipo']));
      if (!mounted || tipo != _filtro || ed != _ed) return; // resultado de otro filtro
      setState(() {
        _presencia = res[0];
        _eventos = evs;
        _loading = false;
      });
    } finally {
      _cargando = false;
      if (_pendiente && mounted) {
        _pendiente = false;
        _cargar();
      } else if (mounted && _loading) {
        setState(() => _loading = false);
      }
    }
  }

  bool _online(Map<String, dynamic> p) {
    final ls = DateTime.tryParse('${p['last_seen'] ?? ''}');
    return ls != null && DateTime.now().toUtc().difference(ls.toUtc()).inMinutes < 5;
  }

  Future<void> _descargarPdf() async {
    final titulo = AppState.instance.edificioNombre;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    String? path;
    String? error;
    try {
      final todos = await Cloud.eventos(tipo: _filtro, edificio: _ed, limit: 1500);
      todos.removeWhere((e) => _internos.contains(e['tipo']));
      path = await PdfExport.actividadNube(todos, _filtro == null ? titulo : '$titulo - ${_tipos[_filtro]}');
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    Navigator.pop(context);
    final p = path;
    if (p != null) {
      try {
        await Share.shareXFiles([XFile(p)], text: 'Actividad OSIRIS - $titulo');
      } catch (_) {}
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo generar el PDF: ${error ?? ''}')));
    }
  }

  Future<void> _eliminarNube() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_forever, color: AppColors.rojo, size: 38),
        title: const Text('Eliminar actividad de la nube'),
        content: Text('Se borrará la actividad de ${AppState.instance.edificioNombre} de la nube. '
            'Los registros de cada celular NO se tocan. Descarga antes el PDF si quieres conservarla.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    final borrado = await Cloud.borrarEventos(edificio: _ed);
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(borrado ? 'Actividad eliminada de la nube.' : 'No se pudo eliminar: ${Cloud.lastError ?? ''}'),
        backgroundColor: borrado ? AppColors.verde : AppColors.rojo));
    _cargar();
  }

  Future<void> _abrirMapa(dynamic lat, dynamic lng) async {
    if (lat == null || lng == null) return;
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final enLinea = _presencia.where(_online).toList();
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Actividad del edificio', style: TextStyle(fontSize: 17)),
          Text(AppState.instance.edificioNombre,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ]),
        actions: [
          IconButton(icon: const Icon(Icons.picture_as_pdf), tooltip: 'Descargar PDF', onPressed: _descargarPdf),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'eliminar') _eliminarNube();
              if (v == 'probar') {
                final r = await Cloud.probar();
                if (!mounted) return;
                await showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Prueba de conexión'),
                    content: SingleChildScrollView(child: SelectableText(r)),
                    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
                  ),
                );
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'probar', child: ListTile(leading: Icon(Icons.wifi_find), title: Text('Probar conexión'))),
              if (AppState.instance.isAdmin)
                const PopupMenuItem(
                    value: 'eliminar', child: ListTile(leading: Icon(Icons.delete_forever), title: Text('Eliminar de la nube'))),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _cargar,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            // Quién está en línea: plegado (no ocupa la pantalla).
            Card(
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                leading: const Icon(Icons.circle, color: AppColors.verde, size: 14),
                title: Text('En línea ahora (${enLinea.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
                children: [
                  if (enLinea.isEmpty) const ListTile(dense: true, title: Text('Ningún guardia en línea')),
                  for (final p in enLinea)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.shield, color: AppColors.verde),
                      title: Text('${p['guardia'] ?? '—'}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(p['en_turno'] == true ? 'En turno' : 'Sin turno'),
                      trailing: p['lat'] != null && p['lng'] != null
                          ? IconButton(
                              icon: const Icon(Icons.location_on_outlined),
                              tooltip: 'Ubicación',
                              onPressed: () => _abrirMapa(p['lat'], p['lng']),
                            )
                          : null,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            // Un solo filtro (antes eran muchos botones).
            DropdownButtonFormField<String?>(
              value: _filtro,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Mostrar',
                prefixIcon: Icon(Icons.filter_list),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Toda la actividad')),
                for (final t in _tipos.entries) DropdownMenuItem<String?>(value: t.key, child: Text(t.value)),
              ],
              onChanged: (v) {
                setState(() {
                  _filtro = v;
                  _limite = 40;
                  _eventos = [];
                });
                _cargar();
              },
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (_eventos.isEmpty)
              const Card(child: ListTile(title: Text('Sin actividad todavía')))
            else ...[
              for (final e in _eventos) EventoTile(e),
              if (_eventos.length >= _limite - 5 && _limite < 600)
                Center(
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() => _limite += 60);
                      _cargar();
                    },
                    icon: const Icon(Icons.expand_more),
                    label: const Text('Ver más'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
