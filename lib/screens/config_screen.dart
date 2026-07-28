import 'dart:convert';
import 'package:flutter/material.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/auth_service.dart';
import '../theme.dart';

class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key});
  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

const _modLabels = {
  'visitas': 'Visitas',
  'visitas_recu': 'Visitas recurrentes',
  'hospedajes': 'Hospedajes',
  'rondas': 'Rondas',
  'propietarios': 'Propietarios',
  'residentes': 'Residentes',
  'vehiculos': 'Vehiculos',
  'incidentes': 'Incidentes',
  'encomiendas': 'Encomiendas',
  'mantenimiento': 'Mantenimiento',
  'contactos': 'Contactos',
  'normativas': 'Normativas',
  'reportes': 'Reportes',
};

class _ConfigScreenState extends State<ConfigScreen> {
  List<Map<String, dynamic>> _edificios = [];
  String _selId = AppState.instance.edificioId;
  Map<String, dynamic> _modulos = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final eds = await db.query('edificios', orderBy: 'nombre');
    final sel = eds.firstWhere((e) => e['id'] == _selId, orElse: () => eds.first);
    if (!mounted) return;
    setState(() {
      _edificios = eds;
      _selId = sel['id'] as String;
      _modulos = Map<String, dynamic>.from(
          jsonDecode((sel['modulos'] as String?) ?? '{}'));
    });
  }

  Future<void> _selectEdificio(String id) async {
    final db = await DB.instance.database;
    final e = (await db.query('edificios', where: 'id=?', whereArgs: [id])).first;
    setState(() {
      _selId = id;
      _modulos = Map<String, dynamic>.from(jsonDecode((e['modulos'] as String?) ?? '{}'));
    });
  }

  Future<void> _toggle(String key, bool val) async {
    setState(() => _modulos[key] = val);
    final db = await DB.instance.database;
    await db.update('edificios', {'modulos': jsonEncode(_modulos)},
        where: 'id=?', whereArgs: [_selId]);
    await Audit.log('EDITAR', 'edificios', _selId, detalle: '$key=$val');
    // Si es el edificio activo, refrescar estado global.
    if (_selId == AppState.instance.edificioId) {
      await AppState.instance.loadEdificio();
    }
  }

  Future<void> _activar(String id) async {
    await AppState.instance.setEdificio(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Edificio activo: ${AppState.instance.edificioNombre}'),
        backgroundColor: AppColors.verde));
    setState(() {});
  }

  Future<void> _nuevoEdificio() async {
    final id = TextEditingController();
    final torres = TextEditingController();
    final dir = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Agregar edificio'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: id, decoration: const InputDecoration(labelText: 'Nombre del edificio')),
            const SizedBox(height: 8),
            TextField(controller: torres, decoration: const InputDecoration(labelText: 'Torres (separadas por coma, opcional)', hintText: 'A, B')),
            const SizedBox(height: 8),
            TextField(controller: dir, decoration: const InputDecoration(labelText: 'Direccion (opcional)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Crear')),
        ],
      ),
    );
    if (ok == true && id.text.trim().isNotEmpty) {
      final db = await DB.instance.database;
      final nombre = id.text.trim();
      final torresList = torres.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      // Por defecto todos los modulos activos; el admin los ajusta luego.
      final mods = {for (final k in _modLabels.keys) k: true};
      try {
        await db.insert('edificios', {
          'id': nombre,
          'nombre': nombre,
          'torres': jsonEncode(torresList),
          'modulos': jsonEncode(mods),
          'direccion': dir.text,
          'cant_deptos': 0,
          'cant_pisos': 0,
        });
        await Audit.log('CREAR', 'edificios', nombre);
        await _load();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Edificio "$nombre" creado'), backgroundColor: AppColors.verde));
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Ya existe un edificio con ese nombre'), backgroundColor: AppColors.rojo));
      }
    }
  }

  Future<void> _nuevoUsuario() async {
    final u = TextEditingController();
    final n = TextEditingController();
    final c = TextEditingController();
    final pw = TextEditingController();
    String rol = 'guardia';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Nuevo usuario'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: u, decoration: const InputDecoration(labelText: 'Usuario')),
              const SizedBox(height: 8),
              TextField(controller: n, decoration: const InputDecoration(labelText: 'Nombre completo')),
              const SizedBox(height: 8),
              TextField(controller: c, decoration: const InputDecoration(labelText: 'Cargo')),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: rol,
                decoration: const InputDecoration(labelText: 'Rol'),
                items: const [
                  DropdownMenuItem(value: 'admin', child: Text('Administrador')),
                  DropdownMenuItem(value: 'supervisor', child: Text('Supervisor')),
                  DropdownMenuItem(value: 'guardia', child: Text('Guardia')),
                  DropdownMenuItem(value: 'franquero', child: Text('Franquero (temporal)')),
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
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Crear')),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        if (rol == 'admin') {
          if (u.text.trim().isEmpty || pw.text.isEmpty) return;
          await AuthService.crearAdmin(usuario: u.text, nombre: n.text, password: pw.text);
        } else {
          if (n.text.trim().isEmpty) return;
          await AuthService.crearGuardia(nombre: n.text, cargo: c.text, rol: rol);
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Usuario creado'), backgroundColor: AppColors.verde));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Error: usuario ya existe'), backgroundColor: AppColors.rojo));
      }
    }
  }

  Future<void> _configAvisos() async {
    final s = AppState.instance;
    String metodo = s.notifMetodo;
    final wa = TextEditingController(text: s.adminWhatsapp);
    final email = TextEditingController(text: s.adminEmail);
    final sender = TextEditingController(text: s.senderEmail);
    final pass = TextEditingController(text: s.senderPass);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Aviso de incidentes al admin'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: metodo,
                decoration: const InputDecoration(labelText: 'Metodo de aviso'),
                items: const [
                  DropdownMenuItem(value: 'whatsapp', child: Text('WhatsApp (un toque)')),
                  DropdownMenuItem(value: 'email', child: Text('Correo automatico')),
                  DropdownMenuItem(value: 'ambos', child: Text('Ambos')),
                  DropdownMenuItem(value: 'ninguno', child: Text('Ninguno')),
                ],
                onChanged: (v) => setD(() => metodo = v ?? 'whatsapp'),
              ),
              const SizedBox(height: 8),
              TextField(controller: wa, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'WhatsApp del admin (ej. 70012345)')),
              const SizedBox(height: 8),
              TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Correo del admin (recibe avisos)')),
              const Divider(height: 24),
              const Text('Cuenta que ENVIA los correos (Gmail):', style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 6),
              TextField(controller: sender, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Correo emisor (Gmail)')),
              const SizedBox(height: 8),
              TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Clave de aplicacion de Gmail')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok == true) {
      await AppState.instance.setNotifConfig(
        metodo: metodo, whatsapp: wa.text, email: email.text,
        sender: sender.text, senderPassword: pass.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ajustes de aviso guardados'), backgroundColor: AppColors.verde));
    }
  }

  @override
  Widget build(BuildContext context) {
    final activo = AppState.instance.edificioId;
    return Scaffold(
      appBar: AppBar(title: const Text('Configuracion')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Edificio', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                for (final e in _edificios)
                  RadioListTile<String>(
                    value: e['id'] as String,
                    groupValue: _selId,
                    onChanged: (v) => _selectEdificio(v!),
                    title: Text(e['nombre'] as String),
                    subtitle: e['id'] == activo
                        ? const Text('Edificio activo', style: TextStyle(color: AppColors.verde))
                        : null,
                    secondary: e['id'] == _selId && e['id'] != activo
                        ? TextButton(onPressed: () => _activar(e['id'] as String), child: const Text('Activar'))
                        : null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _nuevoEdificio,
            icon: const Icon(Icons.add_business),
            label: const Text('Agregar edificio'),
          ),
          const SizedBox(height: 16),
          Text('Modulos de ${_edificios.firstWhere((e) => e['id'] == _selId, orElse: () => {'nombre': ''})['nombre']}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Text('Activa o desactiva modulos. La misma APK sirve para cualquier condominio.',
              style: TextStyle(color: Colors.black54, fontSize: 12)),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                for (final entry in _modLabels.entries)
                  SwitchListTile(
                    value: _modulos[entry.key] == true,
                    onChanged: (v) => _toggle(entry.key, v),
                    title: Text(entry.value),
                    activeColor: AppColors.verde,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text('Usuarios', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_add, color: AppColors.azulMarino),
              title: const Text('Crear nuevo usuario'),
              subtitle: const Text('Admin, supervisor, guardia, conserje, limpieza'),
              onTap: _nuevoUsuario,
            ),
          ),
          const SizedBox(height: 16),
          const Text('Avisos', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.notifications_active, color: Color(0xFFEF6C00)),
              title: const Text('Aviso de incidentes al admin'),
              subtitle: const Text('WhatsApp o correo automatico cuando se reporta un incidente'),
              onTap: _configAvisos,
            ),
          ),
          const SizedBox(height: 24),
          const Card(
            child: ListTile(
              leading: Icon(Icons.info_outline, color: Colors.blueGrey),
              title: Text('OSIRIS v1.0'),
              subtitle: Text('Base de datos local (SQLite). Preparada para sincronizar con Firebase.'),
            ),
          ),
        ],
      ),
    );
  }
}
