import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../db/database_helper.dart';

/// Estado global de sesion: usuario activo, edificio seleccionado y modulos.
class AppState {
  AppState._();
  static final AppState instance = AppState._();

  // Usuario en sesion
  int? userId;
  String? userNombre;
  String? userCargo;
  String? userRol; // admin, supervisor, guardia, conserje, limpieza

  // Turno activo (id de ingreso_turno)
  int? turnoActivoId;

  // Edificio activo
  String edificioId = 'LIMCO II';
  String edificioNombre = 'LIMCO II';
  Map<String, dynamic> modulos = {};
  List<String> torres = [];

  bool get isLogged => userId != null;
  bool get isAdmin => userRol == 'admin';
  bool get isSupervisor => userRol == 'admin' || userRol == 'supervisor';

  bool modulo(String key) => modulos[key] == true;

  Future<void> loadEdificio() async {
    final prefs = await SharedPreferences.getInstance();
    edificioId = prefs.getString('edificio_id') ?? 'LIMCO II';
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

  void logout() {
    userId = null;
    userNombre = null;
    userCargo = null;
    userRol = null;
    turnoActivoId = null;
  }
}
