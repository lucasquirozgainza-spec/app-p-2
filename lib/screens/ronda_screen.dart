import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:geolocator/geolocator.dart';
import '../services/device_context.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/dvr.dart';
import '../services/notifications_service.dart';
import '../theme.dart';
import '../widgets/toast.dart';
import '../services/camara.dart';

class RondaScreen extends StatefulWidget {
  const RondaScreen({super.key});
  @override
  State<RondaScreen> createState() => _RondaScreenState();
}

class _RondaScreenState extends State<RondaScreen> {
  final List<String> _fotos = [];
  final _obs = TextEditingController();
  bool _saving = false;
  final _inicio = DateTime.now();

  // Puntos de control (opcional). Si el edificio no tiene, la ronda es normal.
  List<Map<String, dynamic>> _puntos = [];
  final Set<String> _escaneados = {};

  // Cantidad de fotos obligatorias por ronda (configurable por el admin).
  int get _min => AppState.instance.rondaFotos;

  // RECORRIDO: mientras la pantalla de ronda está abierta se registra el GPS.
  // A la nube va el recorrido y la ubicación de cada foto (las fotos NO).
  StreamSubscription<Position>? _gpsSub;
  final List<Position> _ruta = [];
  final Map<String, Position> _gpsFoto = {};

  @override
  void dispose() {
    _gpsSub?.cancel();
    Camara.alTomar = null;
    _obs.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _cargarPuntos();
    _iniciarGps();
    // cámara nativa: la app queda atrás mientras se toma la foto; al volver
    // cada foto se pide la ubicación de ese momento.
    Camara.alTomar = (f) async {
      try {
        final p = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high, timeLimit: const Duration(seconds: 8));
        _gpsFoto[f] = p;
        if (_ruta.length < 3000) _ruta.add(p);
      } catch (_) {}
    };
  }

  Future<void> _iniciarGps() async {
    await DeviceContext.gps(); // pide el permiso si hace falta
    try {
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 4),
      ).listen((p) {
        if (_ruta.length < 3000) _ruta.add(p);
      }, onError: (_) {});
    } catch (_) {}
  }

  /// Ubicación de una foto: la tomada al volver de la cámara o, si no, el punto
  /// del recorrido más cercano en el tiempo (máx. 2 min de diferencia).
  Map<String, dynamic> _ubicacionFoto(String f, int i) {
    DateTime? t = Camara.tomadaEn[f];
    if (t == null) {
      try { t = File(f).lastModifiedSync(); } catch (_) {}
    }
    Position? p = _gpsFoto[f];
    if (p == null && t != null && _ruta.isNotEmpty) {
      Position mejor = _ruta.first;
      for (final x in _ruta) {
        if ((x.timestamp.difference(t)).abs() < (mejor.timestamp.difference(t)).abs()) mejor = x;
      }
      if ((mejor.timestamp.difference(t)).abs() <= const Duration(minutes: 2)) p = mejor;
    }
    return {
      'n': i + 1,
      if (t != null) 't': t.toUtc().toIso8601String(),
      if (p != null) 'lat': double.parse(p.latitude.toStringAsFixed(6)),
      if (p != null) 'lng': double.parse(p.longitude.toStringAsFixed(6)),
      if (p != null) 'prec': p.accuracy.round(),
    };
  }

  /// Recorrido compacto: hasta 120 puntos [lat, lng, segundos desde el inicio].
  List<List<num>> _rutaCompacta() {
    final r = [..._ruta]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (r.isEmpty) return const [];
    final paso = (r.length / 120).ceil().clamp(1, 1000);
    final out = <List<num>>[];
    for (int i = 0; i < r.length; i += paso) {
      final p = r[i];
      out.add([double.parse(p.latitude.toStringAsFixed(6)), double.parse(p.longitude.toStringAsFixed(6)),
        p.timestamp.difference(_inicio).inSeconds]);
    }
    final u = r.last;
    if (out.isEmpty || out.last[2] != u.timestamp.difference(_inicio).inSeconds) {
      out.add([double.parse(u.latitude.toStringAsFixed(6)), double.parse(u.longitude.toStringAsFixed(6)),
        u.timestamp.difference(_inicio).inSeconds]);
    }
    return out;
  }

  int _metrosRecorridos() {
    final r = [..._ruta]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    double m = 0;
    for (int i = 1; i < r.length; i++) {
      final d = Geolocator.distanceBetween(r[i - 1].latitude, r[i - 1].longitude, r[i].latitude, r[i].longitude);
      if (d < 200) m += d; // saltos raros del GPS no cuentan
    }
    return m.round();
  }

  Future<void> _cargarPuntos() async {
    final db = await DB.instance.database;
    final rows = await db.query('puntos_control',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'id');
    if (!mounted) return;
    setState(() => _puntos = rows);
  }

  Future<void> _escanearPunto() async {
    final res = await Camara.tomar(context, multi: false);
    if (res == null || res.isEmpty) return;
    final raw = await Dvr.leerQr(res.first);
    if (!mounted) return;
    if (raw == null) {
      TopToast.show(context, 'No se leyó el QR. Acércate al punto.', color: AppColors.rojo, icon: Icons.error_outline);
      return;
    }
    final punto = _puntos.where((p) => p['codigo']?.toString() == raw.trim()).toList();
    if (punto.isEmpty) {
      TopToast.show(context, 'Ese QR no es un punto de este edificio.', color: AppColors.rojo, icon: Icons.error_outline);
      return;
    }
    setState(() => _escaneados.add(raw.trim()));
    TopToast.show(context, 'Punto: ${punto.first['nombre']} ✓');
  }

  void _snack(String m) => TopToast.show(context, m, color: AppColors.rojo, icon: Icons.error_outline);

  Future<void> _tomarFotos() async {
    final res = await Camara.tomar(context, multi: true, minFotos: _min, album: 'OSIRIS Rondas', procesada: true);
    if (res != null && res.isNotEmpty && mounted) setState(() => _fotos.addAll(res));
  }

  Future<void> _guardar() async {
    if (_fotos.length < _min) {
      return _snack('Debes tomar al menos $_min fotos (llevas ${_fotos.length})');
    }
    // Si el edificio tiene puntos y faltan por escanear, pedir confirmacion.
    if (_puntos.isNotEmpty && _escaneados.length < _puntos.length) {
      final seguir = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.qr_code_scanner, color: Color(0xFFEF6C00), size: 36),
          title: const Text('Faltan puntos'),
          content: Text('Escaneaste ${_escaneados.length} de ${_puntos.length} puntos. ¿Guardar la ronda igual?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Seguir escaneando')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Guardar igual')),
          ],
        ),
      );
      if (seguir != true) return;
    }
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    final escaneadosDetalle = _puntos
        .where((p) => _escaneados.contains(p['codigo']?.toString()))
        .map((p) => {'nombre': p['nombre'], 'codigo': p['codigo']})
        .toList();
    final id = await db.insert('rondas', {
      'guardia_id': s.userId,
      'guardia_nombre': s.userNombre,
      'puntos': jsonEncode({'fotos_ronda': _fotos, 'puntos_escaneados': escaneadosDetalle}),
      'observaciones': _obs.text,
      'con_novedad': 0,
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'rondas', '$id');

    // CONTROL DE CADENCIA DE RONDAS: compara con la ronda anterior del mismo
    // guardia. Si tardó más de lo debido => "atrasada"; si pasó tanto tiempo que
    // se saltó una o más => "no hizo ronda". Se avisa al guardia y se guarda la
    // advertencia para llevar la cuenta.
    try {
      final cada = s.rondaCada.clamp(1, 12).toDouble();
      // Inicio del turno activo: solo comparamos rondas DENTRO del mismo turno,
      // para no marcar falsas advertencias entre un turno y el siguiente.
      DateTime? turnoIni;
      final tid = s.turnoActivoId;
      if (tid != null) {
        final row = await db.query('ingreso_turno', where: 'id=?', whereArgs: [tid], limit: 1);
        if (row.isNotEmpty) turnoIni = DateTime.tryParse(row.first['created_at']?.toString() ?? '');
      }
      final prev = await db.query('rondas',
          where: 'edificio=? AND guardia_id=? AND id<?',
          whereArgs: [s.edificioId, s.userId, id],
          orderBy: 'id DESC', limit: 1);
      if (prev.isNotEmpty) {
        final tPrev = DateTime.tryParse(prev.first['created_at']?.toString() ?? '');
        if (tPrev != null && (turnoIni == null || !tPrev.isBefore(turnoIni))) {
          final gap = DateTime.now().difference(tPrev).inMinutes / 60.0;
          const tol = 0.5; // 30 min de gracia
          String? msg;
          String? tipo;
          if (gap > 0.4 && gap < 14) { // dentro de la misma jornada
            if (gap >= 2 * cada - tol) {
              final saltadas = (gap / cada).round() - 1;
              if (saltadas >= 1) {
                msg = 'No hizo $saltadas ronda(s): pasaron ${gap.toStringAsFixed(1)} h '
                    'desde la anterior (deben ser cada ${cada.toStringAsFixed(0)} h).';
                tipo = 'ronda_saltada';
              }
            } else if (gap > cada + tol) {
              msg = 'Ronda atrasada: la hizo ${(gap - cada).toStringAsFixed(1)} h tarde '
                  '(deben ser cada ${cada.toStringAsFixed(0)} h).';
              tipo = 'ronda_tarde';
            }
          }
          if (msg != null) {
            await db.insert('advertencias', {
              'guardia_nombre': s.userNombre,
              'mensaje': msg,
              'tipo': tipo,
              'edificio': s.edificioId,
              'created_at': DateTime.now().toIso8601String(),
            });
            Cloud.evento('Advertencia', guardia: s.userNombre, detalle: {'tipo': tipo, 'motivo': msg});
            try { await Notificaciones.mostrarAviso('⚠️ Advertencia de ronda', msg); } catch (_) {}
          }
        }
      }
    } catch (_) {}

    // A la nube va SOLO el registro de la ronda (hora, guardia, puntos y
    // cuántas fotos tomó). Las fotos quedan ÚNICAMENTE en este celular
    // (álbum "OSIRIS Rondas"): así no se llena el espacio de la nube.
    final obsRonda = _obs.text.trim();
    final puntosTxt = _puntos.isNotEmpty ? '${_escaneados.length}/${_puntos.length}' : null;
    final fotosGps = [for (int i = 0; i < _fotos.length; i++) _ubicacionFoto(_fotos[i], i)];
    Cloud.evento('Ronda', detalle: {
      if (obsRonda.isNotEmpty) 'observaciones': obsRonda,
      'fotos': _fotos.length,
      'fotos_en': 'celular',
      if (puntosTxt != null) 'puntos': puntosTxt,
      'fotos_gps': fotosGps,
      'ruta': _rutaCompacta(),
      'ruta_inicio': _inicio.toUtc().toIso8601String(),
      'recorrido_m': _metrosRecorridos(),
    });

    // Compartir las fotos por WhatsApp en 1 clic, a la resolución máxima.
    final guardia = s.userNombre ?? 'Guardia';
    final msg = _obs.text.trim().isEmpty
        ? 'Ronda sin novedad - $guardia - ${DateFormat('dd/MM HH:mm').format(DateTime.now())}'
        : 'Ronda: ${_obs.text.trim()} - $guardia - ${DateFormat('dd/MM HH:mm').format(DateTime.now())}';
    try {
      await Share.shareXFiles(_fotos.map((f) => XFile(f)).toList(), text: msg);
    } catch (_) {}

    if (!mounted) return;
    TopToast.show(context, 'Ronda guardada');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final faltan = (_min - _fotos.length).clamp(0, _min);
    final completo = faltan == 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ronda'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(26),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  'Inicio: ${DateFormat('dd/MM HH:mm').format(_inicio)}  ·  ${AppState.instance.userNombre ?? 'Sin guardia'}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: completo ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(completo ? Icons.check_circle : Icons.photo_camera,
                    color: completo ? AppColors.verde : const Color(0xFFEF6C00), size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    completo
                        ? 'Fotos completas: ${_fotos.length}'
                        : 'Toma $_min fotos de la ronda\nLlevas ${_fotos.length} (faltan $faltan)',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
            onPressed: _tomarFotos,
            icon: const Icon(Icons.camera_alt),
            label: Text('Tomar fotos (${_fotos.length}/$_min)'),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Puedes tomar varias fotos seguidas sin confirmar cada una.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (int i = 0; i < _fotos.length; i++)
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(File(_fotos[i]), width: 92, height: 92, fit: BoxFit.cover, cacheWidth: 276),
                    ),
                    Positioned(
                      right: 0, top: 0,
                      child: GestureDetector(
                        onTap: () => setState(() => _fotos.removeAt(i)),
                        child: Container(
                          decoration: const BoxDecoration(color: AppColors.rojo, shape: BoxShape.circle),
                          child: const Icon(Icons.close, color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          // Puntos de control (solo si el edificio los tiene configurados).
          if (_puntos.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(children: [
              const Icon(Icons.qr_code_scanner, color: Color(0xFF6A1B9A)),
              const SizedBox(width: 8),
              Text('Puntos: ${_escaneados.length}/${_puntos.length}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ]),
            const SizedBox(height: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6A1B9A), minimumSize: const Size(double.infinity, 48)),
              onPressed: _escanearPunto,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Escanear punto', maxLines: 1),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final pt in _puntos)
                  Chip(
                    avatar: Icon(
                      _escaneados.contains(pt['codigo']?.toString()) ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: _escaneados.contains(pt['codigo']?.toString()) ? AppColors.verde : Colors.grey,
                      size: 18,
                    ),
                    label: Text(pt['nombre']?.toString() ?? ''),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          TextField(controller: _obs, maxLines: 3,
              decoration: const InputDecoration(labelText: 'Observaciones / novedades', alignLabelWithHint: true)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: completo ? AppColors.verde : Colors.grey,
                minimumSize: const Size(double.infinity, 52)),
            onPressed: _saving ? null : _guardar,
            icon: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Icon(Icons.save),
            label: const Text('GUARDAR RONDA'),
          ),
        ),
      ),
    );
  }
}
