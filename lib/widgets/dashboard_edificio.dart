import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../screens/guardias_screen.dart';
import '../screens/online_screen.dart';
import '../services/app_state.dart';
import '../services/cloud.dart';
import '../services/estructura.dart';
import '../services/guardias_repo.dart';
import '../services/sesion.dart';
import '../theme.dart';

/// Resumen del EDIFICIO SELECCIONADO (administrador): guardias, visitas,
/// rondas e incidentes de hoy, advertencias y actividad reciente. Todo del
/// edificio de Configuración; nunca mezcla otro.
class DashboardEdificio extends StatefulWidget {
  const DashboardEdificio({super.key});
  @override
  State<DashboardEdificio> createState() => _DashboardEdificioState();
}

class _DashboardEdificioState extends State<DashboardEdificio> {
  List<Map<String, dynamic>> _eventos = [];
  List<Guardia> _guardias = [];
  int _advertencias = 0;
  bool _cargando = true;
  String _ed = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant DashboardEdificio oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Cambió el edificio en Configuración: todo el resumen cambia con él.
    if (_ed != AppState.instance.edificioId) _load();
  }

  Future<void> _load() async {
    final ed = AppState.instance.edificioId;
    _ed = ed;
    setState(() => _cargando = true);
    final bid = Estructura.idEdificio(ed);
    final res = await Future.wait<Object>([
      Cloud.eventos(edificio: ed, limit: 300),
      bid != null && Sesion.vinculado ? GuardiasRepo.delEdificio(bid) : Future.value(<Guardia>[]),
      bid != null && Sesion.vinculado ? GuardiasRepo.advertenciasActivas(bid) : Future.value(<String, int>{}),
    ]);
    if (!mounted || ed != AppState.instance.edificioId) return;
    final evs = (res[0] as List<Map<String, dynamic>>)
      ..removeWhere((e) => const {'Config', 'AdminPass', 'Guardia', 'GuardiaBaja'}.contains(e['tipo']));
    setState(() {
      _eventos = evs;
      _guardias = (res[1] as List<Guardia>).where((g) => g.activo).toList();
      _advertencias = (res[2] as Map<String, int>).values.fold(0, (a, b) => a + b);
      _cargando = false;
    });
  }

  int _hoy(String tipo) {
    final h = DateTime.now();
    return _eventos.where((e) {
      if (e['tipo'] != tipo) return false;
      final t = Cloud.horaEvento(e);
      return t != null && t.year == h.year && t.month == h.month && t.day == h.day;
    }).length;
  }

  Widget _stat(String valor, String etiqueta, IconData icon, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(color: color.withOpacity(.10), borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 2),
            Text(valor, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: color)),
            Text(etiqueta, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final hm = DateFormat('dd/MM HH:mm');
    final unidades = Estructura.unidades(Estructura.idEdificio(_ed));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.apartment, color: AppColors.azulMarino),
            const SizedBox(width: 8),
            Expanded(
              child: Text('EDIFICIO ACTUAL · ${AppState.instance.edificioNombre}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.azulMarino)),
            ),
            IconButton(icon: const Icon(Icons.refresh), tooltip: 'Actualizar', onPressed: _load),
          ]),
          if (_cargando)
            const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
          else ...[
            Row(children: [
              _stat('${_guardias.length}', 'Guardias', Icons.shield, AppColors.verde),
              const SizedBox(width: 6),
              _stat('${_hoy('Visita')}', 'Visitas hoy', Icons.badge, const Color(0xFF00897B)),
              const SizedBox(width: 6),
              _stat('${_hoy('Ronda')}', 'Rondas hoy', Icons.directions_walk, const Color(0xFF6A1B9A)),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              _stat('${_hoy('Incidente')}', 'Incidentes hoy', Icons.warning_amber, AppColors.rojo),
              const SizedBox(width: 6),
              _stat('$_advertencias', 'Advertencias', Icons.report_gmailerrorred, const Color(0xFFEF6C00)),
              const SizedBox(width: 6),
              _stat('${_hoy('Ingreso de turno')}', 'Ingresos hoy', Icons.login, AppColors.azulMarino),
            ]),
            if (Sesion.vinculado) ...[
              const SizedBox(height: 12),
              const Text('GUARDIAS DEL EDIFICIO',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black45, letterSpacing: .8)),
              for (final u in unidades) ...[
                if (unidades.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(u.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                for (final turno in const ['DIURNO', 'NOCTURNO'])
                  Builder(builder: (_) {
                    final g = _guardias.where((g) => g.unitId == u.id && g.turno == turno && g.rol == 'guardia').toList();
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(turno == 'DIURNO' ? Icons.wb_sunny_outlined : Icons.nightlight_outlined,
                          color: g.isEmpty ? Colors.grey : AppColors.azulMarino),
                      title: Text(g.isEmpty ? 'Sin guardia ${turno.toLowerCase()}' : g.first.nombre,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(turno == 'DIURNO' ? 'Diurno' : 'Nocturno'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GuardiasScreen())),
                    );
                  }),
              ],
            ],
            const SizedBox(height: 8),
            const Text('ACTIVIDAD RECIENTE',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black45, letterSpacing: .8)),
            if (_eventos.isEmpty)
              const Padding(padding: EdgeInsets.all(8), child: Text('Sin movimientos recientes')),
            for (final e in _eventos.take(6))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${e['tipo'] ?? ''} · ${e['guardia'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(Cloud.horaEvento(e) == null ? '' : hm.format(Cloud.horaEvento(e)!)),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const OnlineScreen(soloEdificio: true))),
                child: const Text('Ver todos los movimientos'),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
