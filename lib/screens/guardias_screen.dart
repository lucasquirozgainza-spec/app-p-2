import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/auth_service.dart';
import '../theme.dart';

class GuardiasScreen extends StatefulWidget {
  const GuardiasScreen({super.key});
  @override
  State<GuardiasScreen> createState() => _GuardiasScreenState();
}

class _GuardiasScreenState extends State<GuardiasScreen> {
  List<Map<String, dynamic>> _activos = [];
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
        where: "rol IN ('guardia','supervisor','conserje','limpieza') AND activo=1",
        orderBy: 'nombre');
    if (!mounted) return;
    setState(() {
      _activos = activos;
      _personal = personal;
    });
  }

  Future<void> _nuevoGuardia() async {
    final u = TextEditingController();
    final n = TextEditingController();
    final c = TextEditingController(text: 'Guardia de Seguridad');
    final pw = TextEditingController();
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
              TextField(controller: u, decoration: const InputDecoration(labelText: 'Usuario (para ingresar)')),
              const SizedBox(height: 8),
              TextField(controller: c, decoration: const InputDecoration(labelText: 'Cargo')),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: rol,
                decoration: const InputDecoration(labelText: 'Rol'),
                items: const [
                  DropdownMenuItem(value: 'guardia', child: Text('Guardia')),
                  DropdownMenuItem(value: 'supervisor', child: Text('Supervisor')),
                  DropdownMenuItem(value: 'conserje', child: Text('Conserje')),
                  DropdownMenuItem(value: 'limpieza', child: Text('Limpieza')),
                ],
                onChanged: (v) => setD(() => rol = v ?? 'guardia'),
              ),
              const SizedBox(height: 8),
              TextField(controller: pw, obscureText: true, decoration: const InputDecoration(labelText: 'Contrasena')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Registrar')),
          ],
        ),
      ),
    );
    if (ok == true && u.text.trim().isNotEmpty && pw.text.isNotEmpty) {
      try {
        await AuthService.crearUsuario(usuario: u.text, nombre: n.text, cargo: c.text, rol: rol, password: pw.text);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Guardia registrado'), backgroundColor: AppColors.verde));
        _load();
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Ese usuario ya existe'), backgroundColor: AppColors.rojo));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Guardias')),
      floatingActionButton: s.isSupervisor
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
              const Icon(Icons.verified_user, color: AppColors.verde),
              const SizedBox(width: 8),
              Text('En turno ahora (${_activos.length})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 8),
            if (_activos.isEmpty)
              const Card(child: ListTile(title: Text('Ningun guardia con turno activo')))
            else
              for (final t in _activos)
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
                ),
              ),
          ],
        ),
      ),
    );
  }
}
