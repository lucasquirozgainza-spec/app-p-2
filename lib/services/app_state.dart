import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../db/database_helper.dart';
import 'turnos.dart';

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

  // Alarmas y recordatorios
  bool notifRondas = true;      // recordatorio de ronda
  int rondaHoras = 2;           // cada cuantas horas recordar la ronda
  bool alarmaCandados = true;   // alarma a las 00:00 para cerrar candados
  bool controlUniforme = true;  // revisar uniforme (camisa roja / chaleco negro) al iniciar turno

  // Operacion
  int retencionDias = 90;       // borrado automatico de datos/fotos (3 meses)
  int rondaFotos = 10;          // fotos obligatorias por ronda (configurable)
  String turnoIngreso = '';     // horario de ingreso esperado (HH:mm) de ESTE dispositivo
  String turnoSalida = '';      // horario de salida esperado (HH:mm) de ESTE dispositivo
  bool camaraNativa = false;    // true = usar la cámara NATIVA del celular (por dispositivo)
  String bloque = '';           // etiqueta de este celular dentro del edificio (ej. "Bloque A")

  bool modulo(String key) => modulos[key] == true;

  /// Edificio de UNA torre que trabaja SIN conexión: no cruza info con nadie,
  /// así los registros y fotos son instantáneos (no esperan a internet).
  bool get soloLocal => modulos['solo_local'] == true;

  /// Horarios de relevo válidos de ESTE celular (ej. ["08:30", "20:30"]).
  List<String> get horarios => Turnos.limpiar([turnoIngreso, turnoSalida]);

  /// Minutos de atraso al iniciar turno respecto al relevo más cercano de este
  /// celular (positivo = tarde; null = sin horario configurado).
  int? minutosTardeIngreso(DateTime llegada) => Turnos.minutosTarde(llegada, horarios);

  /// Horas extra de un turno con la regla única (ver Turnos).
  double horasExtra(DateTime inicio, DateTime fin, {int nivel = 12, List<String>? horariosTurno}) =>
      Turnos.horasExtra(inicio: inicio, fin: fin, nivel: nivel, horarios: horariosTurno ?? horarios);

  /// Campo de visita habilitado (por defecto SI, salvo que el admin lo apague).
  bool campoVisita(String key) => modulos[key] != false;

  /// Cantidad de digitos de la tarjeta de acceso (por edificio, def. 10).
  int get tarjetaDigitos {
    final v = modulos['tarjeta_digitos'];
    if (v is int) return v;
    return int.tryParse('$v') ?? 10;
  }

  Future<void> loadEdificio() async {
    final prefs = await SharedPreferences.getInstance();
    edificioId = prefs.getString('edificio_id') ?? 'LIMCO II';
    notifMetodo = prefs.getString('notif_metodo') ?? 'whatsapp';
    adminWhatsapp = prefs.getString('admin_whatsapp') ?? '';
    adminEmail = prefs.getString('admin_email') ?? '';
    senderEmail = prefs.getString('sender_email') ?? '';
    senderPass = prefs.getString('sender_pass') ?? '';
    notifRondas = prefs.getBool('notif_rondas') ?? true;
    rondaHoras = prefs.getInt('ronda_horas') ?? 2;
    alarmaCandados = prefs.getBool('alarma_candados') ?? true;
    controlUniforme = prefs.getBool('control_uniforme') ?? true;
    rondaFotos = prefs.getInt('ronda_fotos') ?? 10;
    retencionDias = prefs.getInt('retencion_dias') ?? 90;
    turnoIngreso = prefs.getString('turno_ingreso') ?? '';
    turnoSalida = prefs.getString('turno_salida') ?? '';
    camaraNativa = prefs.getBool('camara_nativa') ?? false;
    bloque = prefs.getString('bloque') ?? '';
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

  Future<void> setRecordatorios({bool? rondas, bool? candados, bool? uniforme, int? rondaHoras}) async {
    final prefs = await SharedPreferences.getInstance();
    if (rondas != null) {
      notifRondas = rondas;
      await prefs.setBool('notif_rondas', rondas);
    }
    if (rondaHoras != null) {
      this.rondaHoras = rondaHoras.clamp(1, 12);
      await prefs.setInt('ronda_horas', this.rondaHoras);
    }
    if (candados != null) {
      alarmaCandados = candados;
      await prefs.setBool('alarma_candados', candados);
    }
    if (uniforme != null) {
      controlUniforme = uniforme;
      await prefs.setBool('control_uniforme', uniforme);
    }
  }

  Future<void> setOperacion({int? rondaFotos, String? turnoIngreso, String? turnoSalida, int? retencionDias}) async {
    final prefs = await SharedPreferences.getInstance();
    if (rondaFotos != null) {
      this.rondaFotos = rondaFotos.clamp(1, 30);
      await prefs.setInt('ronda_fotos', this.rondaFotos);
    }
    if (retencionDias != null) {
      this.retencionDias = retencionDias.clamp(30, 730);
      await prefs.setInt('retencion_dias', this.retencionDias);
    }
    if (turnoIngreso != null) {
      this.turnoIngreso = turnoIngreso;
      await prefs.setString('turno_ingreso', turnoIngreso);
    }
    if (turnoSalida != null) {
      this.turnoSalida = turnoSalida;
      await prefs.setString('turno_salida', turnoSalida);
    }
  }

  /// Elige la cámara: nativa del celular (true) o la de la app (false).
  Future<void> setCamaraNativa(bool v) async {
    camaraNativa = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('camara_nativa', v);
  }

  /// Nombre del bloque/torre de ESTE celular (ej. "Bloque A"). Se adjunta a los
  /// registros para distinguir de qué bloque vino, sin separar el edificio.
  Future<void> setBloque(String v) async {
    bloque = v.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bloque', bloque);
  }

  /// Selecciona el guardia operador (al iniciar turno). Se guarda en el
  /// dispositivo para que el turno siga abierto aunque se cierre la app.
  void setOperador({int? id, String? nombre, String? cargo, String? rol, int? turnoId}) {
    userId = id;
    userNombre = nombre;
    userCargo = cargo;
    userRol = rol;
    turnoActivoId = turnoId;
    _guardarOperador();
  }

  void clearOperador() {
    userId = null;
    userNombre = null;
    userCargo = null;
    userRol = null;
    turnoActivoId = null;
    _guardarOperador();
  }

  Future<void> _guardarOperador() async {
    final prefs = await SharedPreferences.getInstance();
    if (turnoActivoId != null && userId != null) {
      await prefs.setInt('op_turno', turnoActivoId!);
      await prefs.setInt('op_uid', userId!);
      await prefs.setString('op_nombre', userNombre ?? '');
      await prefs.setString('op_cargo', userCargo ?? '');
      await prefs.setString('op_rol', userRol ?? '');
    } else {
      for (final k in ['op_turno', 'op_uid', 'op_nombre', 'op_cargo', 'op_rol']) {
        await prefs.remove(k);
      }
    }
  }

  /// Restaura el turno activo al abrir la app (si el guardia no lo finalizó).
  Future<void> restaurarOperador() async {
    final prefs = await SharedPreferences.getInstance();
    final turno = prefs.getInt('op_turno');
    if (turno == null) return;
    if (!await _turnoSigueActivo(turno)) {
      await _guardarOperador(); // ya no está activo: limpiar
      return;
    }
    userId = prefs.getInt('op_uid');
    userNombre = prefs.getString('op_nombre');
    userCargo = prefs.getString('op_cargo');
    userRol = prefs.getString('op_rol');
    turnoActivoId = turno;
  }

  Future<bool> _turnoSigueActivo(int turnoId) async {
    try {
      final db = await DB.instance.database;
      final rows = await db.query('ingreso_turno', where: 'id=? AND activo=1', whereArgs: [turnoId]);
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
