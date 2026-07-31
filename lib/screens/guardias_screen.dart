import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/auth_service.dart';
import '../services/cloud.dart';
import '../theme.dart';
import 'reporte_personal_screen.dart';
import 'advertencias_screen.dart';

class GuardiasScreen extends StatefulWidget {
  const GuardiasScreen({super.key});
  @override
  State<GuardiasScreen> createState() => _GuardiasScreenState();
}

class _GuardiasScreenState extends State<GuardiasScreen> {
  List<Map<String, dynamic>> _activosLocal = [];
  List<Map<String, dynamic>> _presencia = []; // en linea desde la nube (todos los celulares)
  List<Map<String, dynamic>> _personal = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final activos = await db.query('ingreso_turno',
        where: 'edificio=? AND activo=1', whereArgs: [ed], orderBy: 'id DESC');
    final personal = await db.query('usuarios',
        where: "rol IN ('guardia','supervisor','conserje','limpieza','franquero') AND activo=1 "
            "AND (edificio=? OR edificio IS NULL OR edificio='')",
        whereArgs: [ed],
        orderBy: 'nombre');
    // Presencia en linea de TODOS los celulares (Supabase).
    await Cloud.heartbeat();
    final pres = await Cloud.presencia();
    if (!mounted) return;
    setState(() {
      _activosLocal = activos;
      _personal = personal;
      _presencia = pres;
    });
  }

  bool _enLinea(Map<String, dynamic> p) {
    try {
      final ls = DateTime.parse(p['last_seen'].toString()).toUtc();
      return DateTime.now().toUtc().difference(ls).inMinutes < 5;
    } catch (_) {
      return false;
    }
  }

  /// Guardias en linea de este edificio segun la nube (todos los celulares).
  List<Map<String, dynamic>> get _enTurnoNube {
    final ed = AppState.instance.edificioId;
    return _presencia
        .where((p) => _enLinea(p) && p['en_turno'] == true && (p['edificio']?.toString() ?? '') == ed)
        .toList();
  }

  Future<void> _eliminarPersonal(Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.person_remove, color: AppColors.rojo, size: 36),
        title: const Text('Eliminar personal'),
        content: Text('¿Eliminar a "${p['nombre'] ?? ''}" del personal registrado?'),
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
    if (ok != true) return;
    final db = await DB.instance.database;
    await db.delete('usuarios', where: 'id=?', whereArgs: [p['id']]);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Personal eliminado'), backgroundColor: AppColors.verde));
    _load();
  }

  Future<void> _nuevoGuardia() async {
    final n = TextEditingController();
    final c = TextEditingController(text: 'Guardia de Seguridad');
    String rol = 'guardia';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Registrar guardia'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: n, decoration: const InputDecoration(labelText: 'Nombre completo')),
              const SizedBox(height: 8),
              TextField(controller: c, decoration: const InputDecoration(labelText: 'Cargo')),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: rol,
                decoration: const InputDecoration(labelText: 'Rol'),
                items: const [
                  DropdownMenuItem(value: 'guardia', child: Text('Guardia')),
                  DropdownMenuItem(value: 'franquero', child: Text('Franquero (temporal)')),
                  DropdownMenuItem(value: 'supervisor', child: Text('Supervisor')),
                  DropdownMenuItem(value: 'conserje', child: Text('Conserje')),
                  DropdownMenuItem(value: 'limpieza', child: Text('Limpieza')),
                ],
                onChanged: (v) => setD(() => rol = v ?? 'guardia'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Registrar')),
          ],
        ),
      ),
    );
    if (ok == true && n.text.trim().isNotEmpty) {
      await AuthService.crearGuardia(nombre: n.text.trim(), cargo: c.text, rol: rol);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Guardia registrado'), backgroundColor: AppColors.verde));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final admin = AppState.instance.isAdmin;
    // "En linea" preferimos la nube (todos los celulares); si no hay, lo local.
    final enTurnoNube = _enTurnoNube;
    final usarNube = enTurnoNube.isNotEmpty || Cloud.enabled;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Guardias'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _load,
          ),
          if (admin)
            IconButton(
              icon: const Icon(Icons.warning_amber),
              tooltip: 'Advertencias',
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AdvertenciasScreen())),
            ),
          if (admin)
            IconButton(
              icon: const Icon(Icons.assessment),
              tooltip: 'Reporte de personal (admin)',
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const ReportePersonalScreen())),
            ),
        ],
      ),
      floatingActionButton: admin
          ? FloatingActionButton.extended(
              backgroundColor: AppColors.azulMarino,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.person_add),
              label: const Text('Registrar guardia'),
              onPressed: _nuevoGuardia,
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Row(children: [
              const Icon(Icons.wifi_tethering, color: AppColors.verde),
              const SizedBox(width: 8),
              Text('En línea ahora (${usarNube ? enTurnoNube.length : _activosLocal.length})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ]),
            const Text('En todos los celulares con la app (se actualiza al refrescar).',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            if (usarNube)
              ...(enTurnoNube.isEmpty
                  ? [const Card(child: ListTile(title: Text('Ningún guardia en línea ahora')))]
                  : [
                      for (final p in enTurnoNube)
                        Card(
                          child: ListTile(
                            leading: const CircleAvatar(
                                backgroundColor: Color(0x1A2E7D32),
                                child: Icon(Icons.shield, color: AppColors.verde)),
                            title: Text(p['guardia']?.toString() ?? '—',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text('${p['edificio'] ?? ''} · En turno'),
                            trailing: const Icon(Icons.circle, color: AppColors.verde, size: 12),
                          ),
                        ),
                    ])
            else if (_activosLocal.isEmpty)
              const Card(child: ListTile(title: Text('Ningún guardia con turno activo')))
            else
              for (final t in _activosLocal)
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                        backgroundColor: Color(0x1A2E7D32),
                        child: Icon(Icons.shield, color: AppColors.verde)),
                    title: Text(t['guardia_nombre']?.toString() ?? '—',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        'Ingreso: ${DateFormat('dd/MM HH:mm').format(DateTime.parse(t['created_at'] as String))}'
                        '${t['bateria'] != null ? ' · Bateria ${t['bateria']}%' : ''}'),
                    trailing: const Icon(Icons.circle, color: AppColors.verde, size: 12),
                  ),
                ),

            // El personal registrado (con usuarios) SOLO lo ve el administrador.
            if (admin) ...[
              const SizedBox(height: 20),
              Row(children: [
                const Icon(Icons.groups, color: AppColors.azulMarino),
                const SizedBox(width: 8),
                Text('Personal registrado (${_personal.length})',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 8),
              for (final p in _personal)
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                        backgroundColor: Color(0x1A0A335D),
                        child: Icon(Icons.person, color: AppColors.azulMarino)),
                    title: Text(p['nombre']?.toString() ?? '—',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${p['cargo'] ?? ''} · Usuario: ${p['usuario']} · ${p['rol']}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: AppColors.rojo),
                      tooltip: 'Eliminar',
                      onPressed: () => _eliminarPersonal(p),
                    ),
                  ),
                ),
            ] else ...[
              const SizedBox(height: 24),
              const Card(
                child: ListTile(
                  leading: Icon(Icons.lock, color: Colors.blueGrey),
                  title: Text('Personal y registro'),
                  subtitle: Text('Solo el administrador puede ver el personal y registrar guardias.'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
