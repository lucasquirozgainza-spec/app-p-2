import 'dart:async';
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
  Timer? _espera;
  int _token = 0; // descarta resultados de búsquedas viejas

  @override
  void dispose() {
    _espera?.cancel();
    _q.dispose();
    super.dispose();
  }

  /// Espera a que el guardia deje de escribir (300 ms) antes de buscar.
  void _alEscribir(String q) {
    _espera?.cancel();
    _espera = Timer(const Duration(milliseconds: 300), () => _buscar(q));
  }

  Future<void> _buscar(String q) async {
    q = q.trim();
    final token = ++_token;
    if (q.length < 2) {
      setState(() { _res = []; _buscando = false; });
      return;
    }
    setState(() => _buscando = true);
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final like = '%$q%';
    final out = <_Resultado>[];

    // Las 4 búsquedas EN PARALELO.
    final r = await Future.wait([
      db.query('propietarios',
          where: 'edificio=? AND (depto LIKE ? OR copropietario LIKE ? OR inquilino LIKE ? OR placa LIKE ? OR vehiculo LIKE ?)',
          whereArgs: [ed, like, like, like, like, like],
          limit: 30),
      db.query('vehiculos',
          where: 'edificio=? AND (placa LIKE ? OR nro_parqueo LIKE ? OR depto LIKE ? OR marca LIKE ? OR modelo LIKE ? OR propietario LIKE ?)',
          whereArgs: [ed, like, like, like, like, like, like], limit: 30),
      db.query('residentes', where: 'edificio=? AND nombre LIKE ?', whereArgs: [ed, like], limit: 20),
      db.query('visitas',
          where: 'edificio=? AND (nombre_visita LIKE ? OR ci LIKE ? OR placa LIKE ?)',
          whereArgs: [ed, like, like, like], orderBy: 'id DESC', limit: 20),
    ]);
    if (!mounted || token != _token) return; // llegó una búsqueda más nueva
    final props = r[0], vehs = r[1], resis = r[2], vis = r[3];
    for (final p in props) {
      out.add(_Resultado('Propietario', p['copropietario']?.toString() ?? '—',
          'Depto ${p['depto']} · ${p['telefono'] ?? ''}', Icons.people,
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => PropietarioDetalle(prop: Map<String, dynamic>.from(p), onChanged: () {})))));
    }

    // Vehiculos: por placa, nro de parqueo, depto, marca/modelo, dueño.
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

    for (final r in resis) {
      out.add(_Resultado('Residente', r['nombre']?.toString() ?? '—',
          'Depto ${r['depto']}', Icons.person_outline));
    }

    for (final v in vis) {
      out.add(_Resultado('Visita', v['nombre_visita']?.toString() ?? '—',
          'Depto ${v['depto']} · ${v['estado']}', Icons.badge));
    }

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
          onChanged: _alEscribir,
        ),
      ),
      body: (_buscando && _res.isEmpty)
          ? const Center(child: CircularProgressIndicator())
          : _res.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _q.text.trim().length >= 2
                          ? 'Sin resultados para «${_q.text.trim()}»'
                          : 'Escribe para buscar en todo el edificio',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.black54)),
                  ),
                )
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
