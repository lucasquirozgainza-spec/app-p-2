import 'package:flutter/material.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../theme.dart';
import 'propietarios_screen.dart';
import 'vehiculos_screen.dart';

/// Busqueda global: persona, CI, depto, vehiculo, placa, propietario,
/// residente, visitante.
class BusquedaScreen extends StatefulWidget {
  const BusquedaScreen({super.key});
  @override
  State<BusquedaScreen> createState() => _BusquedaScreenState();
}

class _Resultado {
  final String tipo;
  final String titulo;
  final String subtitulo;
  final IconData icon;
  final VoidCallback? onTap;
  _Resultado(this.tipo, this.titulo, this.subtitulo, this.icon, {this.onTap});
}

class _BusquedaScreenState extends State<BusquedaScreen> {
  final _q = TextEditingController();
  List<_Resultado> _res = [];
  bool _buscando = false;

  Future<void> _buscar(String q) async {
    q = q.trim();
    if (q.length < 2) {
      setState(() => _res = []);
      return;
    }
    setState(() => _buscando = true);
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final like = '%$q%';
    final out = <_Resultado>[];

    final props = await db.query('propietarios',
        where: 'edificio=? AND (depto LIKE ? OR copropietario LIKE ? OR inquilino LIKE ? OR placa LIKE ? OR vehiculo LIKE ?)',
        whereArgs: [ed, like, like, like, like, like],
        limit: 30);
    for (final p in props) {
      out.add(_Resultado('Propietario', p['copropietario']?.toString() ?? '—',
          'Depto ${p['depto']} · ${p['telefono'] ?? ''}', Icons.people,
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => PropietarioDetalle(prop: p, onChanged: () {})))));
    }

    // Vehiculos: por placa, nro de parqueo, depto, marca/modelo, dueño.
    final vehs = await db.query('vehiculos',
        where: 'edificio=? AND (placa LIKE ? OR nro_parqueo LIKE ? OR depto LIKE ? OR marca LIKE ? OR modelo LIKE ? OR propietario LIKE ?)',
        whereArgs: [ed, like, like, like, like, like, like], limit: 30);
    for (final v in vehs) {
      final parq = (v['nro_parqueo']?.toString() ?? '').trim();
      out.add(_Resultado(
          'Vehiculo',
          '${v['placa'] ?? 's/placa'}${parq.isNotEmpty ? '  ·  Parqueo $parq' : ''}',
          'Depto ${v['depto'] ?? '-'} · ${v['marca'] ?? ''} ${v['modelo'] ?? ''}'.trim(),
          Icons.directions_car,
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => VehiculoDetalle(veh: v)))));
    }

    final resis = await db.query('residentes',
        where: 'edificio=? AND nombre LIKE ?', whereArgs: [ed, like], limit: 20);
    for (final r in resis) {
      out.add(_Resultado('Residente', r['nombre']?.toString() ?? '—',
          'Depto ${r['depto']}', Icons.person_outline));
    }

    final vis = await db.query('visitas',
        where: 'edificio=? AND (nombre_visita LIKE ? OR ci LIKE ? OR placa LIKE ?)',
        whereArgs: [ed, like, like, like], orderBy: 'id DESC', limit: 20);
    for (final v in vis) {
      out.add(_Resultado('Visita', v['nombre_visita']?.toString() ?? '—',
          'Depto ${v['depto']} · ${v['estado']}', Icons.badge));
    }

    if (!mounted) return;
    setState(() {
      _res = out;
      _buscando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _q,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          cursorColor: Colors.white,
          decoration: const InputDecoration(
            hintText: 'Buscar persona, CI, depto, placa...',
            hintStyle: TextStyle(color: Colors.white60),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
          ),
          onChanged: _buscar,
        ),
      ),
      body: _buscando
          ? const Center(child: CircularProgressIndicator())
          : _res.isEmpty
              ? const Center(child: Text('Escriba para buscar en todo el edificio'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _res.length,
                  itemBuilder: (_, i) {
                    final r = _res[i];
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppColors.azulMarino.withOpacity(.1),
                          child: Icon(r.icon, color: AppColors.azulMarino, size: 20),
                        ),
                        title: Text(r.titulo, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text('${r.tipo} · ${r.subtitulo}'),
                        trailing: r.onTap != null ? const Icon(Icons.chevron_right) : null,
                        onTap: r.onTap,
                      ),
                    );
                  },
                ),
    );
  }
}
