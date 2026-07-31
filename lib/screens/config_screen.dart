import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/auth_service.dart';
import '../services/excel_import.dart';
import '../services/notifications_service.dart';
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

  Future<void> _cambiarPassword() async {
    final u = TextEditingController(text: 'admin');
    final act = TextEditingController();
    final nue = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cambiar contrasena de admin'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: u, decoration: const InputDecoration(labelText: 'Usuario admin')),
            const SizedBox(height: 8),
            TextField(controller: act, obscureText: true, decoration: const InputDecoration(labelText: 'Contrasena actual')),
            const SizedBox(height: 8),
            TextField(controller: nue, obscureText: true, decoration: const InputDecoration(labelText: 'Nueva contrasena')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Cambiar')),
        ],
      ),
    );
    if (ok == true) {
      final err = await AuthService.cambiarPasswordAdmin(u.text, act.text, nue.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(err ?? 'Contrasena actualizada'),
          backgroundColor: err == null ? AppColors.verde : AppColors.rojo));
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

  Future<void> _importarExcel() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['xlsx', 'xls'],
    );
    if (res == null || res.files.single.path == null) return;
    if (!mounted) return;
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    final r = await ExcelImport.importar(res.files.single.path!, _selId);
    if (!mounted) return;
    Navigator.pop(context); // cerrar spinner
    if (r.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('No se pudo leer el Excel: ${r.error}'), backgroundColor: AppColors.rojo));
      return;
    }
    await Audit.log('IMPORTAR', 'propietarios', _selId, detalle: '${r.propietarios} prop, ${r.residentes} resi');
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: AppColors.verde, size: 40),
        title: const Text('Importación lista'),
        content: Text('Se cargaron ${r.propietarios} propietarios'
            '${r.residentes > 0 ? ' y ${r.residentes} residentes' : ''} al edificio.'),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Entendido'))],
      ),
    );
  }

  Future<void> _pickHora(bool ingreso) async {
    final actual = ingreso ? AppState.instance.turnoIngreso : AppState.instance.turnoSalida;
    TimeOfDay inicial = const TimeOfDay(hour: 8, minute: 0);
    if (actual.contains(':')) {
      final parts = actual.split(':');
      inicial = TimeOfDay(hour: int.tryParse(parts[0]) ?? 8, minute: int.tryParse(parts[1]) ?? 0);
    }
    final t = await showTimePicker(context: context, initialTime: inicial);
    if (t == null) return;
    final hhmm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    await AppState.instance.setOperacion(
        turnoIngreso: ingreso ? hhmm : null, turnoSalida: ingreso ? null : hhmm);
    if (mounted) setState(() {});
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
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _nuevoEdificio,
                icon: const Icon(Icons.add_business),
                label: const Text('Agregar edificio'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _importarExcel,
                icon: const Icon(Icons.upload_file),
                label: const Text('Importar Excel'),
              ),
            ),
          ]),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('El Excel debe tener columnas como: Depto, Nombre/Propietario, Teléfono/Celular '
                '(opcional: Inquilino, Parentesco). Se cargan al edificio seleccionado arriba.',
                style: TextStyle(fontSize: 11, color: Colors.black54)),
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
          const Text('Campos que se piden en Visitas', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Text('Ej: en edificios sin tarjeta de acceso, apaga "Tarjeta".',
              style: TextStyle(color: Colors.black54, fontSize: 12)),
          const SizedBox(height: 8),
          Card(
            child: Column(children: [
              for (final e in const {
                'v_tarjeta': 'Tarjeta de acceso',
                'v_carnet': 'Foto del carnet (obligatoria)',
                'v_vehiculo': 'Preguntar por vehiculo',
                'v_motivo': 'Motivo de la visita',
              }.entries)
                SwitchListTile(
                  value: _modulos[e.key] != false,
                  onChanged: (v) => _toggle(e.key, v),
                  title: Text(e.value),
                  activeColor: AppColors.verde,
                ),
            ]),
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
          Card(
            child: ListTile(
              leading: const Icon(Icons.password, color: AppColors.azulMarino),
              title: const Text('Cambiar contrasena de admin'),
              onTap: _cambiarPassword,
            ),
          ),
          const SizedBox(height: 16),
          const Text('Alarmas y recordatorios', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Text('Notificaciones automaticas en el telefono del guardia.',
              style: TextStyle(color: Colors.black54, fontSize: 12)),
          const SizedBox(height: 8),
          Card(
            child: Column(children: [
              SwitchListTile(
                value: AppState.instance.notifRondas,
                activeColor: AppColors.verde,
                secondary: const Icon(Icons.directions_walk, color: Color(0xFF6A1B9A)),
                title: const Text('Recordatorio de ronda cada 2 horas'),
                subtitle: const Text('Avisa a las 00, 02, 04 ... 22 hs'),
                onChanged: (v) async {
                  await AppState.instance.setRecordatorios(rondas: v);
                  await Notificaciones.programarRecordatorios();
                  setState(() {});
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: AppState.instance.alarmaCandados,
                activeColor: AppColors.verde,
                secondary: const Icon(Icons.lock_clock, color: AppColors.rojo),
                title: const Text('Alarma de cerrar candados (00:00)'),
                subtitle: const Text('Recordatorio cada noche a medianoche'),
                onChanged: (v) async {
                  await AppState.instance.setRecordatorios(candados: v);
                  await Notificaciones.programarRecordatorios();
                  setState(() {});
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: AppState.instance.controlUniforme,
                activeColor: AppColors.verde,
                secondary: const Icon(Icons.checkroom, color: AppColors.azulMarino),
                title: const Text('Controlar uniforme al iniciar turno'),
                subtitle: const Text('Detecta camisa roja / chaleco negro en la foto'),
                onChanged: (v) async {
                  await AppState.instance.setRecordatorios(uniforme: v);
                  setState(() {});
                },
              ),
            ]),
          ),
          const SizedBox(height: 16),
          const Text('Rondas y turnos', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Text('Fotos por ronda y horario de este dispositivo.',
              style: TextStyle(color: Colors.black54, fontSize: 12)),
          const SizedBox(height: 8),
          Card(
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.photo_camera, color: Color(0xFF6A1B9A)),
                title: const Text('Fotos obligatorias por ronda'),
                subtitle: Text('Actualmente: ${AppState.instance.rondaFotos} fotos'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () async {
                      await AppState.instance.setOperacion(rondaFotos: AppState.instance.rondaFotos - 1);
                      setState(() {});
                    },
                  ),
                  Text('${AppState.instance.rondaFotos}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () async {
                      await AppState.instance.setOperacion(rondaFotos: AppState.instance.rondaFotos + 1);
                      setState(() {});
                    },
                  ),
                ]),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.login, color: AppColors.verde),
                title: const Text('Horario de ingreso (este dispositivo)'),
                subtitle: Text(AppState.instance.turnoIngreso.isEmpty ? 'Sin definir' : AppState.instance.turnoIngreso),
                trailing: const Icon(Icons.schedule),
                onTap: () => _pickHora(true),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout, color: AppColors.rojo),
                title: const Text('Horario de salida (este dispositivo)'),
                subtitle: Text(AppState.instance.turnoSalida.isEmpty ? 'Sin definir' : AppState.instance.turnoSalida),
                trailing: const Icon(Icons.schedule),
                onTap: () => _pickHora(false),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text('Los turnos se calculan de 12 horas; lo que pase de 12 h cuenta como hora extra.',
                    style: TextStyle(fontSize: 11, color: Colors.black54)),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          const Text('Borrado automático de datos', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Text('Todo lo que registra la app (con sus fotos y videos) se borra al pasar este tiempo. '
              'Los PDF descargados se conservan.', style: TextStyle(color: Colors.black54, fontSize: 12)),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.auto_delete, color: AppColors.rojo),
              title: const Text('Conservar datos por'),
              subtitle: Text('${(AppState.instance.retencionDias / 30).round()} mes(es)  ·  ${AppState.instance.retencionDias} días'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () async {
                    final meses = (AppState.instance.retencionDias / 30).round();
                    await AppState.instance.setOperacion(retencionDias: ((meses - 1).clamp(1, 24)) * 30);
                    setState(() {});
                  },
                ),
                Text('${(AppState.instance.retencionDias / 30).round()}m',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () async {
                    final meses = (AppState.instance.retencionDias / 30).round();
                    await AppState.instance.setOperacion(retencionDias: ((meses + 1).clamp(1, 24)) * 30);
                    setState(() {});
                  },
                ),
              ]),
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
