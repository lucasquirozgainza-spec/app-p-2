import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/auth_service.dart';
import '../services/cloud.dart';
import '../services/estructura.dart';
import '../services/guardias_repo.dart';
import '../services/sesion.dart';

import '../services/excel_import.dart';
import '../services/notifications_service.dart';
import '../services/retention.dart';
import '../services/turnos.dart';
import '../theme.dart';
import 'puntos_control_screen.dart';

class ConfigScreen extends StatefulWidget {
  final String? initialEdificio; // admin: abrir configurando este edificio
  const ConfigScreen({super.key, this.initialEdificio});
  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

// Solo módulos que realmente muestran u ocultan algo en la app.
const _modLabels = {
  'visitas': 'Visitas',
  'visitas_recu': 'Visitas recurrentes',
  'hospedajes': 'Hospedajes',
  'rondas': 'Rondas',
  'propietarios': 'Propietarios',
  'vehiculos': 'Vehiculos',
  'incidentes': 'Incidentes',
  'encomiendas': 'Encomiendas',
  'mantenimiento': 'Mantenimiento',
  'normativas': 'Normativas',
};

class _ConfigScreenState extends State<ConfigScreen> {
  List<Map<String, dynamic>> _edificios = [];
  late String _selId = widget.initialEdificio ?? AppState.instance.edificioId;
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
    // Admin vinculado: torres y celulares del edificio (desde la nube).
    if (Sesion.esAdmin) {
      Estructura.actualizar().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  Future<void> _selectEdificio(String id) async {
    final db = await DB.instance.database;
    final e = (await db.query('edificios', where: 'id=?', whereArgs: [id])).first;
    if (!mounted) return;
    setState(() {
      _selId = id;
      _modulos = Map<String, dynamic>.from(jsonDecode((e['modulos'] as String?) ?? '{}'));
    });
  }

  Future<void> _setMod(String key, dynamic val) async {
    setState(() => _modulos[key] = val);
    final db = await DB.instance.database;
    final json = jsonEncode(_modulos);
    await db.update('edificios', {'modulos': json}, where: 'id=?', whereArgs: [_selId]);
    await Audit.log('EDITAR', 'edificios', _selId, detalle: '$key=$val');
    if (_selId == AppState.instance.edificioId) {
      await AppState.instance.loadEdificio();
    }
    // Publicar a los otros dispositivos del edificio (config remota).
    Cloud.pushConfig(_selId, json);
  }

  int get _toleranciaMin => Turnos.toleranciaDe(_modulos);

  int get _tarjetaDigitos {
    final v = _modulos['tarjeta_digitos'];
    if (v is int) return v;
    return int.tryParse('$v') ?? 10;
  }

  Future<void> _toggle(String key, bool val) async {
    setState(() => _modulos[key] = val);
    final db = await DB.instance.database;
    final json = jsonEncode(_modulos);
    await db.update('edificios', {'modulos': json}, where: 'id=?', whereArgs: [_selId]);
    await Audit.log('EDITAR', 'edificios', _selId, detalle: '$key=$val');
    // Si es el edificio activo, refrescar estado global.
    if (_selId == AppState.instance.edificioId) {
      await AppState.instance.loadEdificio();
    }
    // Publicar a los otros dispositivos del edificio (config remota).
    Cloud.pushConfig(_selId, json);
  }

  /// Borra AHORA todos los datos/registros y de prueba (menos guardias y cámaras).
  Future<void> _eliminarTodoAhora() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_forever, color: AppColors.rojo, size: 40),
        title: const Text('¿Eliminar todo ahora?'),
        content: const Text('Se borrarán TODOS los registros y datos de prueba de la app '
            '(visitas, rondas, turnos, incidentes, encomiendas, propietarios, residentes, '
            'contactos, fotos y videos) y se limpiará la nube.\n\n'
            'NO se borran los guardias ni las cámaras. Esta acción no se puede deshacer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sí, eliminar todo'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    int total = 0;
    try {
      total = await Retention.borrarTodoAhora();
    } catch (_) {}
    if (!mounted) return;
    Navigator.pop(context); // cerrar spinner
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: AppColors.verde, size: 38),
        title: const Text('Datos eliminados'),
        content: Text('Se borraron $total registros y sus fotos/videos. '
            'Los guardias y las cámaras se mantienen.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Listo'))],
      ),
    );
  }

  /// Vacía TODA la actividad de la nube (todos los edificios).
  Future<void> _vaciarNube() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.cloud_off, color: Color(0xFFEF6C00), size: 38),
        title: const Text('¿Vaciar la nube?'),
        content: const Text('Se borrará TODA la actividad guardada en la nube (todos los '
            'edificios) para liberar espacio. Los registros locales de cada celular NO se tocan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF6C00)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Vaciar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    final okB = await Cloud.borrarEventos(edificio: null);
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(okB ? 'Nube vaciada.' : 'No se pudo vaciar: ${Cloud.lastError ?? ''}'),
        backgroundColor: okB ? AppColors.verde : AppColors.rojo));
  }

  Future<void> _activar(String id) async {
    await AppState.instance.setEdificio(id);
    // Admin vinculado: el edificio queda publicado en la nube (con su unidad
    // "Principal") para registrar sus guardias y vincular sus celulares.
    if (Sesion.esAdmin) {
      await Estructura.publicarEdificio(id, AppState.instance.edificioNombre);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Edificio activo: ${AppState.instance.edificioNombre}'),
        backgroundColor: AppColors.verde));
    if (mounted) setState(() {});
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
                isExpanded: true, // texto largo con "…" en vez de desbordar
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

  /// Resumen del horario de relevo de este celular.
  String _resumenHorario() {
    final h = AppState.instance.horarios;
    if (AppState.instance.horariosConfigurados.isEmpty) {
      return '${h.join(' y ')} · turno normal de 12 h';
    }
    if (h.length == 1) return 'Relevo ${h[0]} · turnos de 24 h';
    final d1 = Turnos.entre(h[0], h[1]), d2 = Turnos.entre(h[1], h[0]);
    return d1 == d2
        ? '${h[0]} y ${h[1]} · turnos de ${Turnos.duracion(d1)}'
        : '${h[0]} y ${h[1]} · ${Turnos.duracion(d1)} / ${Turnos.duracion(d2)}';
  }

  /// Horario de relevo de ESTE celular: una o dos horas de cambio de turno.
  /// Muestra inicio, fin y duración de cada turno y valida antes de guardar.
  Future<void> _editarHorario() async {
    final s = AppState.instance;
    final l1 = Turnos.limpiar([s.turnoIngreso]), l2 = Turnos.limpiar([s.turnoSalida]);
    String? r1 = l1.isEmpty ? null : l1.first;
    String? r2 = l2.isEmpty ? null : l2.first;

    Future<String?> elegir(String? actual) async {
      final p = Turnos.parseHora(actual) ?? const [8, 0];
      final t = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: p[0], minute: p[1]),
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
      );
      return t == null ? null : Turnos.fmtHora(t.hour, t.minute);
    }

    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final lista = Turnos.limpiar([r1, r2]);
        String detalle;
        String? error;
        if (lista.isEmpty) {
          detalle = 'Sin horario: no se marcan atrasos y cada turno se toma de 12 h.';
        } else if (lista.length == 1) {
          detalle = 'Un solo relevo a las ${lista[0]}: turnos de 24 h.';
        } else {
          final d1 = Turnos.entre(lista[0], lista[1]), d2 = Turnos.entre(lista[1], lista[0]);
          detalle = 'Turno 1: ${lista[0]} → ${lista[1]} (${Turnos.duracion(d1)})\n'
              'Turno 2: ${lista[1]} → ${lista[0]} (${Turnos.duracion(d2)})';
          if (d1.inHours < 6 || d2.inHours < 6) {
            error = 'Un turno quedaría de menos de 6 h. Revisa las horas.';
          }
        }
        Widget fila(String titulo, String? valor, VoidCallback onTap) => ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(titulo),
              trailing: OutlinedButton(onPressed: onTap, child: Text(valor ?? '— : —')),
            );
        return AlertDialog(
          title: const Text('Horario de relevo'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            fila('Relevo 1 (ej. día)', r1, () async {
              final v = await elegir(r1);
              if (v != null) setD(() => r1 = v);
            }),
            fila('Relevo 2 (ej. noche)', r2, () async {
              final v = await elegir(r2 ?? r1);
              if (v != null) setD(() => r2 = v);
            }),
            const SizedBox(height: 8),
            Text(detalle, style: const TextStyle(fontSize: 13)),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error, style: const TextStyle(color: AppColors.rojo, fontWeight: FontWeight.w600)),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'quitar'), child: const Text('Quitar')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: error == null ? () => Navigator.pop(ctx, 'ok') : null, child: const Text('Guardar')),
          ],
        );
      }),
    );
    if (res == null) return;
    if (res == 'quitar') {
      await s.setOperacion(turnoIngreso: '', turnoSalida: '');
    } else {
      final lista = Turnos.limpiar([r1, r2]);
      await s.setOperacion(
          turnoIngreso: lista.isNotEmpty ? lista[0] : '', turnoSalida: lista.length > 1 ? lista[1] : '');
    }
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
                isExpanded: true, // texto largo con "…" en vez de desbordar
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

  Future<void> _editarBloque() async {
    final c = TextEditingController(text: AppState.instance.bloque);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Bloque de este celular'),
        content: TextField(
          controller: c,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Ej. Bloque A', prefixIcon: Icon(Icons.account_tree)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok == true) {
      await AppState.instance.setBloque(c.text);
      if (mounted) setState(() {});
    }
  }

  /// Sección plegable (acordeón) para dejar la configuración más limpia: cada
  /// bloque se abre solo cuando el admin lo necesita, en vez de un scroll largo.
  // ---------------------------------------------------------------------------
  // VÍNCULO del celular y UNIDADES (torres/dispositivos) del edificio
  // ---------------------------------------------------------------------------

  Future<void> _vincular() async {
    final c = TextEditingController();
    String? error;
    bool enviando = false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => PopScope(
          canPop: !enviando,
          child: AlertDialog(
          scrollable: true,
          title: const Text('Vincular celular'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Ingresa el código que generó el administrador para este edificio y torre.'),
            const SizedBox(height: 10),
            TextField(
              controller: c,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Código', hintText: 'ABCD-1234'),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error ?? '', style: const TextStyle(color: AppColors.rojo)),
              ),
          ]),
          actions: [
            TextButton(onPressed: enviando ? null : () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(
              onPressed: enviando
                  ? null
                  : () async {
                      if (c.text.trim().isEmpty) return;
                      setD(() {
                        enviando = true;
                        error = null;
                      });
                      final r = await Sesion.activar(c.text, etiqueta: AppState.instance.bloque);
                      if (!ctx.mounted) return;
                      if (r != null) {
                        setD(() {
                          enviando = false;
                          error = r;
                        });
                        return;
                      }
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    },
              child: enviando
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : const Text('Vincular'),
            ),
          ],
        ),
        ),
      ),
    );
    if (ok != true) return;
    await AppState.instance.aplicarVinculo();
    await Estructura.actualizar();
    if (Sesion.esAdmin) await Estructura.publicarEdificio(AppState.instance.edificioId, AppState.instance.edificioNombre);
    await GuardiasRepo.cerrarTurnosHuerfanos();
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: AppColors.verde,
      content: Text(Sesion.esAdmin
          ? 'Celular vinculado como ADMINISTRADOR'
          : 'Vinculado a ${Sesion.buildingName ?? ''} · ${Sesion.unitName ?? ''}'),
    ));
  }

  Future<void> _desvincular() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('¿Desvincular este celular?'),
        content: const Text('Deja de sincronizar con su edificio hasta que se vincule con un código nuevo. '
            'No se borra nada.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.rojo),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Desvincular'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Sesion.desvincular();
    if (mounted) setState(() {});
  }

  Widget _tarjetaVinculo() {
    final v = Sesion.vinculado;
    final titulo = !v
        ? 'Este celular no está vinculado'
        : (Sesion.esAdmin
            ? 'Celular de ADMINISTRADOR'
            : '${Sesion.buildingName ?? ''} · ${Sesion.unitName ?? ''}');
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(v ? Icons.verified_user : Icons.link_off, color: v ? AppColors.verde : const Color(0xFFEF6C00)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(titulo, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(
                  !v
                      ? 'Vincúlalo con el código del administrador: así solo trabaja con su edificio y su torre.'
                      : (Sesion.esAdmin
                          ? 'Trabaja con el edificio elegido arriba.'
                          : 'Solo ve y registra datos de este edificio; solo los guardias de esta torre.'),
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ]),
            ),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: v
                ? TextButton(onPressed: _desvincular, child: const Text('Desvincular'))
                : FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
                    onPressed: _vincular,
                    child: const Text('Vincular con código'),
                  ),
          ),
        ]),
      ),
    );
  }

  Future<void> _mostrarCodigo(Map<String, String> r, String para) async {
    if (!mounted) return;
    final codigo = r['codigo'];
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(codigo == null ? 'No se pudo crear el código' : 'Código para $para'),
        content: codigo == null
            ? Text(r['error'] ?? '')
            : Column(mainAxisSize: MainAxisSize.min, children: [
                SelectableText(codigo,
                    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold, letterSpacing: 3)),
                const SizedBox(height: 8),
                const Text('Úsalo UNA vez en el celular: Configuración → Vincular celular. Vence en 7 días.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
              ]),
        actions: [
          if (codigo != null)
            TextButton(
              onPressed: () => Share.share('Código OSIRIS para $para: $codigo'),
              child: const Text('Compartir'),
            ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
        ],
      ),
    );
  }

  Future<String?> _pedirTexto(String titulo, {String inicial = '', String etiqueta = 'Nombre'}) async {
    final c = TextEditingController(text: inicial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(titulo),
        content: TextField(controller: c, autofocus: true, decoration: InputDecoration(labelText: etiqueta)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
        ],
      ),
    );
    final t = c.text.trim();
    return ok == true && t.isNotEmpty ? t : null;
  }

  /// Unidades (torres/dispositivos) del edificio elegido y sus celulares.
  List<Widget> _unidadesYCelulares() {
    final nombreEd = _edificios.where((e) => e['id'] == _selId).map((e) => '${e['nombre']}').toList();
    final nombre = nombreEd.isEmpty ? _selId : nombreEd.first;
    final bid = Estructura.idEdificio(_selId);
    if (bid == null) {
      return [
        ListTile(
          dense: true,
          leading: const Icon(Icons.cloud_upload_outlined),
          title: const Text('Publicar este edificio en la nube'),
          subtitle: const Text('Necesario para registrar sus guardias y vincular sus celulares.'),
          onTap: () async {
            await Estructura.publicarEdificio(_selId, nombre);
            if (mounted) setState(() {});
          },
        ),
      ];
    }
    final unidades = Estructura.unidades(bid);
    return [
      for (final u in unidades)
        ListTile(
          dense: true,
          leading: const Icon(Icons.domain, color: Color(0xFF00695C)),
          title: Text(u.name),
          subtitle: const Text('Toca para renombrar'),
          onTap: () async {
            final n = await _pedirTexto('Renombrar unidad', inicial: u.name);
            if (n == null) return;
            final e = await Estructura.renombrarUnidad(u.id, n);
            if (!mounted) return;
            if (e != null) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e), backgroundColor: AppColors.rojo));
            }
            setState(() {});
          },
          trailing: TextButton(
            onPressed: () async {
              final r = await Estructura.crearCodigo(buildingId: bid, unitId: u.id);
              await _mostrarCodigo(r, '$nombre · ${u.name}');
            },
            child: const Text('Código'),
          ),
        ),
      ListTile(
        dense: true,
        leading: const Icon(Icons.add, color: Color(0xFF00695C)),
        title: const Text('Agregar torre / dispositivo'),
        onTap: () async {
          final n = await _pedirTexto('Nueva unidad', etiqueta: 'Nombre (ej. Torre 2)');
          if (n == null) return;
          final e = await Estructura.crearUnidad(bid, n);
          if (!mounted) return;
          if (e != null) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e), backgroundColor: AppColors.rojo));
          }
          setState(() {});
        },
      ),
      ListTile(
        dense: true,
        leading: const Icon(Icons.phone_android, color: Color(0xFF00695C)),
        title: const Text('Celulares vinculados'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _celulares(bid, nombre),
      ),
      ListTile(
        dense: true,
        leading: const Icon(Icons.admin_panel_settings, color: AppColors.azulMarino),
        title: const Text('Código de administrador'),
        subtitle: const Text('Para vincular otro celular de administrador'),
        onTap: () async {
          final r = await Estructura.crearCodigo(admin: true);
          await _mostrarCodigo(r, 'administrador');
        },
      ),
    ];
  }

  Future<void> _celulares(String bid, String nombre) async {
    final lista = await Estructura.dispositivos(bid);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Celulares · $nombre'),
        content: SizedBox(
          width: double.maxFinite,
          child: lista.isEmpty
              ? const Text('Ningún celular vinculado a este edificio.')
              : ListView(shrinkWrap: true, children: [
                  for (final d in lista)
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.phone_android, color: d['active'] == false ? Colors.grey : AppColors.verde),
                      title: Text('${d['label'] ?? d['device_id']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${Estructura.nombreUnidad(d['unit_id']?.toString())}'
                          '${d['active'] == false ? ' · desactivado' : ''}'),
                      trailing: d['active'] == false
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.block, color: AppColors.rojo),
                              tooltip: 'Desactivar celular',
                              onPressed: () async {
                                await Estructura.desactivarDispositivo('${d['device_id']}');
                                if (ctx.mounted) Navigator.pop(ctx);
                              },
                            ),
                    ),
                ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar'))],
      ),
    );
  }

  Widget _seccion(String title, IconData icon, Color color, List<Widget> children, {bool abierta = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          initiallyExpanded: abierta,
          leading: Icon(icon, color: color),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          childrenPadding: EdgeInsets.zero,
          children: children,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activo = AppState.instance.edificioId;
    return Scaffold(
      appBar: AppBar(title: const Text('Configuracion')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Este celular', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          _tarjetaVinculo(),
          const SizedBox(height: 12),
          const Text('Edificio', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                // Un celular de guardia vinculado solo puede trabajar con SU edificio.
                for (final e in _edificios.where((e) => !Sesion.esGuardia || e['id'] == Sesion.buildingCode))
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
                label: const Text('Nuevo'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _importarExcel,
                icon: const Icon(Icons.upload_file),
                label: const Text('Excel'),
              ),
            ),
          ]),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Excel: Depto, Nombre, Teléfono (opcional Inquilino).',
                style: TextStyle(fontSize: 11, color: Colors.black54)),
          ),
          _seccion('Módulos', Icons.widgets, const Color(0xFF1565C0), [
            for (final entry in _modLabels.entries)
              SwitchListTile(
                dense: true,
                value: _modulos[entry.key] == true,
                onChanged: (v) => _toggle(entry.key, v),
                title: Text(entry.value),
                activeColor: AppColors.verde,
              ),
          ]),
          _seccion('Conexión', Icons.wifi, const Color(0xFF546E7A), [
            SwitchListTile(
              dense: true,
              value: _modulos['solo_local'] == true,
              onChanged: (v) => _toggle('solo_local', v),
              secondary: const Icon(Icons.wifi_off, color: Color(0xFF546E7A)),
              title: const Text('Trabajar sin conexión'),
              subtitle: const Text('Edificio de una torre: registros instantáneos, no usa la nube.'),
              activeColor: AppColors.verde,
            ),
          ]),
          _seccion('Horas de guardias', Icons.timer_outlined, const Color(0xFF00838F), [
            ListTile(
              dense: true,
              leading: const Icon(Icons.more_time, color: Color(0xFF00838F)),
              title: const Text('Tolerancia de relevo'),
              subtitle: const Text('Hasta este margen no cuenta; pasado, se cuentan todos los minutos.'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  tooltip: 'Menos 5 min',
                  onPressed: _toleranciaMin <= 0
                      ? null
                      : () => _setMod('tolerancia_min', (_toleranciaMin - 5).clamp(0, 60)),
                ),
                Text('$_toleranciaMin min', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: 'Más 5 min',
                  onPressed: _toleranciaMin >= 60
                      ? null
                      : () => _setMod('tolerancia_min', (_toleranciaMin + 5).clamp(0, 60)),
                ),
              ]),
            ),
          ]),
          _seccion('Cámara', Icons.photo_camera, const Color(0xFF283593), [
            SwitchListTile(
              dense: true,
              value: AppState.instance.camaraNativa,
              onChanged: (v) async {
                await AppState.instance.setCamaraNativa(v);
                if (mounted) setState(() {});
              },
              secondary: const Icon(Icons.camera, color: Color(0xFF283593)),
              title: const Text('Usar la cámara del celular'),
              subtitle: const Text('Usa la cámara nativa del teléfono (respeta las proporciones y '
                  'confirma cada foto). Apagado: cámara de la app (instantánea, sin confirmar). '
                  'Este ajuste es de ESTE celular.'),
              activeColor: AppColors.verde,
            ),
          ]),
          if (Sesion.esAdmin)
            _seccion('Torres y celulares', Icons.domain, const Color(0xFF00695C), _unidadesYCelulares()),
          if (!Sesion.vinculado)
          _seccion('Bloque de este celular', Icons.account_tree, const Color(0xFF00695C), [
            ListTile(
              dense: true,
              leading: const Icon(Icons.account_tree, color: Color(0xFF00695C)),
              title: Text(AppState.instance.bloque.isEmpty ? 'Sin bloque asignado' : AppState.instance.bloque),
              subtitle: const Text('Nombre de este celular dentro del edificio (ej. "Bloque A"). '
                  'Los dos bloques cruzan datos igual; solo sirve para saber de dónde vino cada registro.'),
              trailing: const Icon(Icons.edit),
              onTap: _editarBloque,
            ),
          ]),
          _seccion('Campos de Visitas', Icons.badge, const Color(0xFF00897B), [
              for (final e in const {
                'v_tarjeta': 'Tarjeta de acceso',
                'v_carnet': 'Foto del carnet',
                'v_vehiculo': 'Vehículo',
                'v_motivo': 'Motivo',
              }.entries)
                SwitchListTile(
                  dense: true,
                  value: _modulos[e.key] != false,
                  onChanged: (v) => _toggle(e.key, v),
                  title: Text(e.value),
                  activeColor: AppColors.verde,
                ),
              if (_modulos['v_tarjeta'] != false)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.pin, color: Color(0xFFEF6C00)),
                  title: const Text('Dígitos de la tarjeta'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _setMod('tarjeta_digitos', (_tarjetaDigitos - 1).clamp(3, 16)),
                    ),
                    Text('$_tarjetaDigitos', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: () => _setMod('tarjeta_digitos', (_tarjetaDigitos + 1).clamp(3, 16)),
                    ),
                  ]),
                ),
            ]),
          _seccion('Usuarios', Icons.people_alt, AppColors.azulMarino, [
              ListTile(
                dense: true,
                leading: const Icon(Icons.person_add, color: AppColors.azulMarino),
                title: const Text('Crear usuario'),
                onTap: _nuevoUsuario,
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.password, color: AppColors.azulMarino),
                title: const Text('Cambiar contraseña de admin'),
                onTap: _cambiarPassword,
              ),
          ]),
          _seccion('Alarmas y recordatorios', Icons.notifications_active, const Color(0xFFEF6C00), [
              SwitchListTile(
                value: AppState.instance.notifRondas,
                activeColor: AppColors.verde,
                secondary: const Icon(Icons.directions_walk, color: Color(0xFF6A1B9A)),
                title: const Text('Recordatorio de ronda'),
                subtitle: Text('Cada ${AppState.instance.rondaHoras} hora(s)'),
                onChanged: (v) async {
                  await AppState.instance.setRecordatorios(rondas: v);
                  await Notificaciones.programarRecordatorios();
                  if (mounted) setState(() {});
                },
              ),
              if (AppState.instance.notifRondas)
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 72, right: 12),
                  title: const Text('Cada cuántas horas'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () async {
                        await AppState.instance.setRecordatorios(rondaHoras: AppState.instance.rondaHoras - 1);
                        await Notificaciones.programarRecordatorios();
                        if (mounted) setState(() {});
                      },
                    ),
                    Text('${AppState.instance.rondaHoras} h', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: () async {
                        await AppState.instance.setRecordatorios(rondaHoras: AppState.instance.rondaHoras + 1);
                        await Notificaciones.programarRecordatorios();
                        if (mounted) setState(() {});
                      },
                    ),
                  ]),
                ),
              const Divider(height: 1),
              SwitchListTile(
                value: AppState.instance.alarmaCandados,
                activeColor: AppColors.verde,
                secondary: const Icon(Icons.lock_clock, color: AppColors.rojo),
                title: const Text('Alarma de candados (00:00)'),
                onChanged: (v) async {
                  await AppState.instance.setRecordatorios(candados: v);
                  await Notificaciones.programarRecordatorios();
                  if (mounted) setState(() {});
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: AppState.instance.controlUniforme,
                activeColor: AppColors.verde,
                secondary: const Icon(Icons.checkroom, color: AppColors.azulMarino),
                title: const Text('Controlar uniforme'),
                onChanged: (v) async {
                  await AppState.instance.setRecordatorios(uniforme: v);
                  if (mounted) setState(() {});
                },
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.notifications_active, color: Color(0xFFEF6C00)),
                title: const Text('Probar alarma ahora'),
                onTap: () async {
                  await Notificaciones.mostrarAviso('Prueba de alarma OSIRIS',
                      'Si ves esto, las notificaciones funcionan. Recuerda desactivar el ahorro de batería para OSIRIS.');
                },
              ),
            ]),
          _seccion('Rondas y turnos', Icons.directions_walk, const Color(0xFF6A1B9A), [
              ListTile(
                leading: const Icon(Icons.photo_camera, color: Color(0xFF6A1B9A)),
                title: const Text('Fotos obligatorias por ronda'),
                subtitle: Text('Actualmente: ${AppState.instance.rondaFotos} fotos'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () async {
                      await AppState.instance.setOperacion(rondaFotos: AppState.instance.rondaFotos - 1);
                      if (mounted) setState(() {});
                    },
                  ),
                  Text('${AppState.instance.rondaFotos}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () async {
                      await AppState.instance.setOperacion(rondaFotos: AppState.instance.rondaFotos + 1);
                      if (mounted) setState(() {});
                    },
                  ),
                ]),
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.schedule, color: AppColors.verde),
                title: const Text('Horario de relevo'),
                subtitle: Text(_resumenHorario()),
                trailing: const Icon(Icons.chevron_right),
                onTap: _editarHorario,
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.qr_code_2, color: Color(0xFF6A1B9A)),
                title: const Text('Puntos de ronda (QR)'),
                subtitle: const Text('Opcional'),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PuntosControlScreen())),
              ),
          ]),
          _seccion('Datos', Icons.storage, AppColors.rojo, [
              ListTile(
                dense: true,
                leading: const Icon(Icons.auto_delete, color: AppColors.rojo),
                title: const Text('Conservar datos por'),
              subtitle: Text('${(AppState.instance.retencionDias / 30).round()} mes(es)  ·  ${AppState.instance.retencionDias} días'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () async {
                    final meses = (AppState.instance.retencionDias / 30).round();
                    await AppState.instance.setOperacion(retencionDias: ((meses - 1).clamp(1, 24)) * 30);
                    if (mounted) setState(() {});
                  },
                ),
                Text('${(AppState.instance.retencionDias / 30).round()}m',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () async {
                    final meses = (AppState.instance.retencionDias / 30).round();
                    await AppState.instance.setOperacion(retencionDias: ((meses + 1).clamp(1, 24)) * 30);
                    if (mounted) setState(() {});
                  },
                ),
              ]),
            ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.delete_forever, color: AppColors.rojo),
                title: const Text('Eliminar todo ahora'),
                subtitle: const Text('Borra registros y datos de prueba (no los guardias).'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _eliminarTodoAhora,
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.cloud_off, color: Color(0xFFEF6C00)),
                title: const Text('Vaciar la nube ahora'),
                subtitle: const Text('Borra la actividad de la nube (se limpia sola cada 3 meses).'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _vaciarNube,
              ),
          ]),
          _seccion('Avisos', Icons.campaign, const Color(0xFFEF6C00), [
              ListTile(
                dense: true,
                leading: const Icon(Icons.notifications_active, color: Color(0xFFEF6C00)),
                title: const Text('Aviso de incidentes al admin'),
                subtitle: const Text('WhatsApp o correo'),
                onTap: _configAvisos,
              ),
          ]),
          const SizedBox(height: 24),
          const Card(
            child: ListTile(
              dense: true,
              leading: Icon(Icons.info_outline, color: Colors.blueGrey),
              title: Text('OSIRIS'),
              subtitle: Text('Base de datos local'),
            ),
          ),
        ],
      ),
    );
  }
}
