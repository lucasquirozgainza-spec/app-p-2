import 'package:flutter/material.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/dvr.dart';
import '../theme.dart';
import '../widgets/toast.dart';
import 'camera_screen.dart';
import 'camara_view_screen.dart';
import 'camara_playback_screen.dart';
import 'camara_multi_screen.dart';

/// Monitoreo: lista de DVR/camaras del edificio. Se agregan por QR (Dahua) o
/// manual, y se ven en vivo o en grabaciones (RTSP, sin depender de DMSS).
class MonitoreoScreen extends StatefulWidget {
  const MonitoreoScreen({super.key});
  @override
  State<MonitoreoScreen> createState() => _MonitoreoScreenState();
}

class _MonitoreoScreenState extends State<MonitoreoScreen> {
  List<Map<String, dynamic>> _cams = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final rows = await db.query('camaras',
        where: 'edificio=?', whereArgs: [AppState.instance.edificioId], orderBy: 'id DESC');
    if (!mounted) return;
    setState(() => _cams = rows);
  }

  Future<void> _escanearQr() async {
    final res = await Navigator.push<List<String>>(
        context, MaterialPageRoute(builder: (_) => const CameraScreen(multi: false)));
    if (res == null || res.isEmpty) return;
    final raw = await Dvr.leerQr(res.first);
    if (!mounted) return;
    if (raw == null) {
      TopToast.show(context, 'No se detectó un QR. Intenta de nuevo o agrega manual.',
          color: AppColors.rojo, icon: Icons.error_outline);
      return;
    }
    final cfg = Dvr.parseQr(raw);
    if (cfg == null) {
      TopToast.show(context, 'QR no reconocido. Agrega el equipo manualmente.',
          color: AppColors.rojo, icon: Icons.error_outline);
      return;
    }
    _formulario(prefill: cfg);
  }

  Future<void> _formulario({DvrConfig? prefill, Map<String, dynamic>? existente}) async {
    final nombre = TextEditingController(text: existente?['nombre']?.toString() ?? prefill?.nombre ?? '');
    final host = TextEditingController(text: existente?['host']?.toString() ?? '');
    final hostRemoto = TextEditingController(text: existente?['host_remoto']?.toString() ?? '');
    final puerto = TextEditingController(text: '${existente?['puerto'] ?? prefill?.puerto ?? 554}');
    final usuario = TextEditingController(text: existente?['usuario']?.toString() ?? prefill?.usuario ?? 'admin');
    final clave = TextEditingController(text: existente?['clave']?.toString() ?? prefill?.clave ?? '');
    final canales = TextEditingController(text: '${existente?['canales'] ?? prefill?.canales ?? 1}');
    final serial = prefill?.serial ?? existente?['serial']?.toString() ?? '';

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(existente == null ? 'Agregar equipo' : 'Editar equipo'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (serial.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Serial P2P: $serial\nPara ver en la app pon la IP local o el DDNS del DVR.',
                    style: const TextStyle(fontSize: 11, color: Colors.black54)),
              ),
            TextField(controller: nombre, decoration: const InputDecoration(labelText: 'Nombre')),
            const SizedBox(height: 6),
            TextField(controller: host, decoration: const InputDecoration(labelText: 'IP local (WiFi del edificio, ej. 192.168.1.108)')),
            const SizedBox(height: 6),
            TextField(controller: hostRemoto, decoration: const InputDecoration(labelText: 'DDNS/IP pública (datos móviles, opcional)')),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: TextField(controller: puerto, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Puerto RTSP'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: canales, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Canales'))),
            ]),
            const SizedBox(height: 6),
            TextField(controller: usuario, decoration: const InputDecoration(labelText: 'Usuario')),
            const SizedBox(height: 6),
            TextField(controller: clave, decoration: const InputDecoration(labelText: 'Contraseña')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true) return;
    final db = await DB.instance.database;
    final datos = {
      'edificio': AppState.instance.edificioId,
      'nombre': nombre.text.trim().isEmpty ? 'DVR' : nombre.text.trim(),
      'host': host.text.trim(),
      'host_remoto': hostRemoto.text.trim(),
      'puerto': int.tryParse(puerto.text) ?? 554,
      'usuario': usuario.text.trim(),
      'clave': clave.text,
      'canales': int.tryParse(canales.text) ?? 1,
      'serial': serial,
      'marca': 'dahua',
      'created_at': DateTime.now().toIso8601String(),
    };
    if (existente == null) {
      await db.insert('camaras', datos);
    } else {
      await db.update('camaras', datos, where: 'id=?', whereArgs: [existente['id']]);
    }
    _load();
  }

  Future<void> _eliminar(Map<String, dynamic> cam) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Eliminar equipo'),
        content: Text('¿Eliminar "${cam['nombre'] ?? ''}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
              onPressed: () => Navigator.pop(context, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    final db = await DB.instance.database;
    await db.delete('camaras', where: 'id=?', whereArgs: [cam['id']]);
    _load();
  }

  void _acciones(Map<String, dynamic> cam) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.videocam, color: AppColors.verde),
            title: const Text('Ver en vivo'),
            onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => CamaraViewScreen(cam: cam))); },
          ),
          ListTile(
            leading: const Icon(Icons.history, color: AppColors.azulMarino),
            title: const Text('Ver grabaciones'),
            onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => CamaraPlaybackScreen(cam: cam))); },
          ),
          if (AppState.instance.isAdmin) ...[
            ListTile(
              leading: const Icon(Icons.edit, color: Color(0xFF37474F)),
              title: const Text('Editar'),
              onTap: () { Navigator.pop(context); _formulario(existente: cam); },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: AppColors.rojo),
              title: const Text('Eliminar'),
              onTap: () { Navigator.pop(context); _eliminar(cam); },
            ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monitoreo'),
        actions: [
          IconButton(
            icon: Icon(AppState.instance.camaraRemota ? Icons.signal_cellular_alt : Icons.wifi),
            tooltip: AppState.instance.camaraRemota ? 'Modo: Datos (DDNS)' : 'Modo: WiFi local',
            onPressed: () => setState(() => AppState.instance.camaraRemota = !AppState.instance.camaraRemota),
          ),
          IconButton(
            icon: const Icon(Icons.grid_view),
            tooltip: 'Vista múltiple',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CamaraMultiScreen())),
          ),
        ],
      ),
      floatingActionButton: AppState.instance.isAdmin
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              FloatingActionButton.extended(
                heroTag: 'qr',
                backgroundColor: AppColors.azulMarino,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Escanear QR'),
                onPressed: _escanearQr,
              ),
              const SizedBox(height: 10),
              FloatingActionButton.extended(
                heroTag: 'manual',
                backgroundColor: const Color(0xFF37474F),
                icon: const Icon(Icons.add),
                label: const Text('Manual'),
                onPressed: () => _formulario(),
              ),
            ])
          : null,
      body: _cams.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Sin equipos. El admin puede escanear el QR del DVR o agregarlo manualmente.',
                    textAlign: TextAlign.center),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _cams.length,
              itemBuilder: (_, i) {
                final cam = _cams[i];
                final sinHost = (cam['host']?.toString() ?? '').isEmpty;
                return Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                        backgroundColor: Color(0x1A0A335D),
                        child: Icon(Icons.dvr, color: AppColors.azulMarino)),
                    title: Text(cam['nombre']?.toString() ?? 'DVR',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(sinHost
                        ? 'Falta la IP/DDNS · toca para configurar'
                        : '${cam['host']}:${cam['puerto']} · ${cam['canales']} canales'),
                    trailing: const Icon(Icons.more_vert),
                    onTap: () => sinHost ? _formulario(existente: cam) : _acciones(cam),
                  ),
                );
              },
            ),
    );
  }
}
