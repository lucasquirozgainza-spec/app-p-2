import '../db/database_helper.dart';
import 'app_state.dart';
import 'cloud.dart';

/// Guardia registrado en un edificio. Su identificador es el CI (carnet):
/// un guardia nuevo, con otro CI, nunca hereda nada de otro.
class Guardia {
  final int idLocal;
  final String ci, nombre, edificio, turno; // turno: DIURNO | NOCTURNO | FRANQUERO
  final String bloque;                       // '' si el edificio no tiene bloques
  final bool activo;
  final DateTime? desde;
  Guardia({
    required this.idLocal,
    required this.ci,
    required this.nombre,
    required this.edificio,
    required this.turno,
    this.bloque = '',
    this.activo = true,
    this.desde,
  });

  bool get franquero => turno == 'FRANQUERO';
  String get turnoTexto => turno == 'NOCTURNO' ? 'Nocturno' : (franquero ? 'Franquero' : 'Diurno');

  static Guardia? de(Map<String, dynamic> r) {
    final ci = '${r['documento'] ?? ''}'.trim();
    if (ci.isEmpty) return null;
    return Guardia(
      idLocal: r['id'] as int,
      ci: ci,
      nombre: '${r['nombre'] ?? ''}',
      edificio: '${r['edificio'] ?? ''}',
      turno: '${r['turno'] ?? 'DIURNO'}',
      bloque: '${r['unit_id'] ?? ''}',
      activo: (r['activo'] ?? 1) == 1,
      desde: DateTime.tryParse('${r['fecha_inicio'] ?? r['created_at'] ?? ''}'),
    );
  }
}

/// Guardias por EDIFICIO (independientes entre edificios). Se guardan en el
/// celular y se publican a la nube como eventos "Guardia"/"GuardiaBaja" con
/// su CI, así todos los celulares del mismo edificio tienen la misma lista.
class GuardiasService {
  /// Clave local única: edificio + CI (el mismo CI en otro edificio es otro
  /// registro, con sus propias horas).
  static String clave(String edificio, String ci) => '$edificio:${ci.trim()}';

  static String limpiarCi(String ci) => ci.trim().replaceAll(RegExp(r'\s+'), '').toUpperCase();

  /// Guardias del edificio (activos primero).
  static Future<List<Guardia>> delEdificio(String edificio, {bool incluirInactivos = false}) async {
    final db = await DB.instance.database;
    final rows = await db.query('usuarios',
        where: "edificio=? AND guard_uuid IS NOT NULL AND documento IS NOT NULL AND documento!=''"
            '${incluirInactivos ? '' : ' AND activo=1'}',
        whereArgs: [edificio],
        orderBy: 'activo DESC, turno, nombre COLLATE NOCASE');
    return [for (final r in rows) if (Guardia.de(r) != null) Guardia.de(r)!];
  }

  /// Registra un guardia en el edificio ACTIVO. Devuelve null si salió bien
  /// o el mensaje de error.
  static Future<String?> registrar({
    required String nombre,
    required String ci,
    required String turno,
    String bloque = '',
  }) async {
    final s = AppState.instance;
    final ed = s.edificioId;
    final c = limpiarCi(ci);
    if (nombre.trim().isEmpty) return 'Escribe el nombre';
    if (c.length < 4) return 'Escribe el CI (carnet)';
    final lista = await delEdificio(ed);
    if (lista.any((g) => g.ci == c)) return 'Ya hay un guardia activo con el CI $c en este edificio.';
    // Un diurno y un nocturno por bloque; franqueros los que hagan falta.
    if (turno != 'FRANQUERO') {
      final ya = lista.where((g) => g.turno == turno && g.bloque == bloque).toList();
      if (ya.isNotEmpty) {
        return 'Ya existe un guardia ${turno == 'NOCTURNO' ? 'nocturno' : 'diurno'} activo'
            '${bloque.isEmpty ? '' : ' en $bloque'} (${ya.first.nombre}). '
            'Dalo de baja antes de registrar uno nuevo.';
      }
    }
    final db = await DB.instance.database;
    final ahora = DateTime.now().toIso8601String();
    final k = clave(ed, c);
    final datos = {
      'nombre': nombre.trim(),
      'cargo': turno == 'FRANQUERO' ? 'Franquero' : 'Guardia de Seguridad',
      'rol': turno == 'FRANQUERO' ? 'franquero' : 'guardia',
      'activo': 1,
      'edificio': ed,
      'unit_id': bloque,
      'turno': turno,
      'documento': c,
      'fecha_inicio': ahora,
    };
    // Si ese CI estuvo antes en el edificio (dado de baja), vuelve a estar
    // activo con sus datos nuevos; si no, es un registro nuevo.
    final n = await db.update('usuarios', datos, where: 'guard_uuid=?', whereArgs: [k]);
    if (n == 0) {
      await db.insert('usuarios', {
        ...datos,
        'usuario': 'g_$k',
        'pass_hash': 'ci',
        'salt': 'ci',
        'guard_uuid': k,
        'created_at': ahora,
      });
    }
    Cloud.evento('Guardia', guardia: nombre.trim(), detalle: {
      'ci': c,
      'nombre': nombre.trim(),
      'turno': turno,
      'bloque': bloque,
      'rol': datos['rol'],
      'cargo': datos['cargo'],
    });
    return null;
  }

  /// Baja: deja de aparecer, pero su historial queda (no se borra).
  static Future<void> darDeBaja(Guardia g) async {
    final db = await DB.instance.database;
    await db.update('usuarios', {'activo': 0, 'fecha_fin': DateTime.now().toIso8601String()},
        where: 'guard_uuid=?', whereArgs: [clave(g.edificio, g.ci)]);
    Cloud.evento('GuardiaBaja', guardia: g.nombre, edificio: g.edificio, detalle: {'ci': g.ci, 'nombre': g.nombre});
  }

  /// ELIMINA al guardia del edificio (en este y en los demás celulares).
  /// Con [borrarDatos]: también borra de la nube SOLO de este edificio sus
  /// registros (ingresos, salidas, rondas, visitas...) y sus turnos locales.
  /// Devuelve null si salió bien o el mensaje de error.
  static Future<String?> eliminar(Guardia g, {bool borrarDatos = false}) async {
    // 1) En la nube: sus altas/bajas anteriores (si no, se "revive" al
    //    sincronizar) y, si se pidió, todos sus registros de este edificio.
    final ok = await Cloud.borrarGuardiaNube(g.edificio, g.ci, conRegistros: borrarDatos);
    if (!ok && !AppState.instance.soloLocal) {
      return 'No se pudo borrar en la nube (sin conexión). Intenta con internet.';
    }
    // 2) En este celular.
    final db = await DB.instance.database;
    final k = clave(g.edificio, g.ci);
    final u = await db.query('usuarios', columns: ['id'], where: 'guard_uuid=?', whereArgs: [k]);
    if (borrarDatos) {
      final ids = [for (final r in u) r['id']];
      await db.delete('ingreso_turno', where: 'edificio=? AND guard_uuid=?', whereArgs: [g.edificio, g.ci]);
      for (final id in ids) {
        await db.delete('salida_turno', where: 'guardia_id=?', whereArgs: [id]);
      }
    } else {
      // Sus turnos quedan como historial, cerrados.
      await db.update('ingreso_turno', {'activo': 0}, where: 'edificio=? AND guard_uuid=? AND activo=1',
          whereArgs: [g.edificio, g.ci]);
    }
    await db.delete('usuarios', where: 'guard_uuid=?', whereArgs: [k]);
    // 3) Aviso a los demás celulares del edificio para que también lo quiten.
    Cloud.evento('GuardiaBaja', guardia: g.nombre, edificio: g.edificio,
        detalle: {'ci': g.ci, 'nombre': g.nombre, 'eliminado': true});
    return null;
  }

  /// Aplica en ESTE celular un alta/baja publicada por otro celular.
  static Future<void> aplicarRemoto(String edificio, Map det, {required bool baja}) async {
    final c = limpiarCi('${det['ci'] ?? ''}');
    if (c.isEmpty) return;
    final db = await DB.instance.database;
    final k = clave(edificio, c);
    if (baja) {
      if (det['eliminado'] == true) {
        await db.delete('usuarios', where: 'guard_uuid=?', whereArgs: [k]);
      } else {
        await db.update('usuarios', {'activo': 0}, where: 'guard_uuid=?', whereArgs: [k]);
      }
      return;
    }
    final turno = '${det['turno'] ?? 'DIURNO'}';
    final datos = {
      'nombre': '${det['nombre'] ?? ''}'.trim(),
      'cargo': '${det['cargo'] ?? 'Guardia de Seguridad'}',
      'rol': '${det['rol'] ?? (turno == 'FRANQUERO' ? 'franquero' : 'guardia')}',
      'activo': 1,
      'edificio': edificio,
      'unit_id': '${det['bloque'] ?? ''}',
      'turno': turno,
      'documento': c,
    };
    final n = await db.update('usuarios', datos, where: 'guard_uuid=?', whereArgs: [k]);
    if (n == 0) {
      await db.insert('usuarios', {
        ...datos,
        'usuario': 'g_$k',
        'pass_hash': 'ci',
        'salt': 'ci',
        'guard_uuid': k,
        'fecha_inicio': DateTime.now().toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
      });
    }
  }
}
