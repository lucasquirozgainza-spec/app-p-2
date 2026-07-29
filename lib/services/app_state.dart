import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../db/database_helper.dart';

/// Estado global. La app queda SIEMPRE abierta (sin login diario).
/// - "operador" = guardia que está usando el equipo (se selecciona al iniciar turno).
/// - "isAdmin" = elevación temporal para entrar a Configuración.
class AppState {
  AppState._();
  static final AppState instance = AppState._();

  // Guardia operador actual (seleccionado, sin escribir nombre)
  int? userId;
  String? userNombre;
  String? userCargo;
  String? userRol;

  // Turno activo del operador
  int? turnoActivoId;

  // Elevación de administrador
  bool isAdmin = false;
  bool get isSupervisor => isAdmin;

  // Edificio activo
  String edificioId = 'LIMCO II';
  String edificioNombre = 'LIMCO II';
  Map<String, dynamic> modulos = {};
  List<String> torres = [];

  // Ajustes de notificación de incidentes
  String notifMetodo = 'whatsapp'; // whatsapp | email | ambos | ninguno
  String adminWhatsapp = '';
  String adminEmail = '';
  String senderEmail = ''; // cuenta Gmail que envía
  String senderPass = '';  // clave de aplicación de esa cuenta

  bool get hayOperador => userId != null;
  bool modulo(String key) => modulos[key] == true;

  /// Campo de visita habilitado (por defecto SI, salvo que el admin lo apague).
  bool campoVisita(String key) => modulos[key] != false;

  Future<void> loadEdificio() async {
    final prefs = await SharedPreferences.getInstance();
    edificioId = prefs.getString('edificio_id') ?? 'LIMCO II';
    notifMetodo = prefs.getString('notif_metodo') ?? 'whatsapp';
    adminWhatsapp = prefs.getString('admin_whatsapp') ?? '';
    adminEmail = prefs.getString('admin_email') ?? '';
    senderEmail = prefs.getString('sender_email') ?? '';
    senderPass = prefs.getString('sender_pass') ?? '';
    final db = await DB.instance.database;
    final rows = await db.query('edificios', where: 'id = ?', whereArgs: [edificioId]);
    if (rows.isEmpty) {
      final all = await db.query('edificios', limit: 1);
      if (all.isNotEmpty) {
        _applyEdificio(all.first);
        await prefs.setString('edificio_id', edificioId);
      }
      return;
    }
    _applyEdificio(rows.first);
  }

  void _applyEdificio(Map<String, dynamic> row) {
    edificioId = row['id'] as String;
    edificioNombre = row['nombre'] as String;
    modulos = (row['modulos'] != null && (row['modulos'] as String).isNotEmpty)
        ? Map<String, dynamic>.from(jsonDecode(row['modulos'] as String))
        : {};
    torres = (row['torres'] != null && (row['torres'] as String).isNotEmpty)
        ? List<String>.from(jsonDecode(row['torres'] as String))
        : [];
  }

  Future<void> setEdificio(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('edificio_id', id);
    await loadEdificio();
  }

  Future<void> setNotifConfig({
    String? metodo,
    String? whatsapp,
    String? email,
    String? sender,
    String? senderPassword,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (metodo != null) {
      notifMetodo = metodo;
      await prefs.setString('notif_metodo', metodo);
    }
    if (whatsapp != null) {
      adminWhatsapp = whatsapp.trim();
      await prefs.setString('admin_whatsapp', adminWhatsapp);
    }
    if (email != null) {
      adminEmail = email.trim();
      await prefs.setString('admin_email', adminEmail);
    }
    if (sender != null) {
      senderEmail = sender.trim();
      await prefs.setString('sender_email', senderEmail);
    }
    if (senderPassword != null) {
      senderPass = senderPassword;
      await prefs.setString('sender_pass', senderPassword);
    }
  }

  /// Selecciona el guardia operador (al iniciar turno).
  void setOperador({int? id, String? nombre, String? cargo, String? rol, int? turnoId}) {
    userId = id;
    userNombre = nombre;
    userCargo = cargo;
    userRol = rol;
    turnoActivoId = turnoId;
  }

  void clearOperador() {
    userId = null;
    userNombre = null;
    userCargo = null;
    userRol = null;
    turnoActivoId = null;
  }
}
