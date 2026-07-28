import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../services/crypto_util.dart';

/// Acceso central a la base de datos SQLite (offline-first).
class DB {
  DB._();
  static final DB instance = DB._();
  Database? _db;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'condocontrol.db');
    return openDatabase(
      path,
      version: 4,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, v) async {
        await _createSchema(db);
        await _seed(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          try {
            await db.execute('ALTER TABLE vehiculos ADD COLUMN telefono TEXT');
          } catch (_) {}
        }
        if (oldV < 3) {
          try {
            await db.execute('ALTER TABLE visitas ADD COLUMN tarjeta_devuelta INTEGER DEFAULT 0');
          } catch (_) {}
          try {
            await db.execute('''CREATE TABLE IF NOT EXISTS advertencias (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              guardia_nombre TEXT, mensaje TEXT, tipo TEXT,
              edificio TEXT, created_at TEXT NOT NULL)''');
          } catch (_) {}
        }
        if (oldV < 4) {
          try {
            await db.execute('ALTER TABLE visitas ADD COLUMN tarjeta_num TEXT');
          } catch (_) {}
        }
      },
    );
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE usuarios (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        usuario TEXT UNIQUE NOT NULL,
        nombre TEXT NOT NULL,
        cargo TEXT,
        rol TEXT NOT NULL,
        pass_hash TEXT NOT NULL,
        salt TEXT NOT NULL,
        foto TEXT,
        activo INTEGER DEFAULT 1,
        created_at TEXT
      )''');

    await db.execute('''
      CREATE TABLE edificios (
        id TEXT PRIMARY KEY,
        nombre TEXT NOT NULL,
        torres TEXT,
        modulos TEXT,
        logo TEXT,
        direccion TEXT,
        cant_deptos INTEGER,
        cant_pisos INTEGER
      )''');

    await db.execute('''
      CREATE TABLE ingreso_turno (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        guardia_id INTEGER,
        guardia_nombre TEXT,
        cargo TEXT,
        foto TEXT,
        gps_lat REAL,
        gps_lng REAL,
        bateria INTEGER,
        dispositivo TEXT,
        observaciones TEXT,
        edificio TEXT,
        activo INTEGER DEFAULT 1,
        created_at TEXT NOT NULL,
        sync_status INTEGER DEFAULT 0
      )''');

    await db.execute('''
      CREATE TABLE salida_turno (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        turno_id INTEGER,
        guardia_id INTEGER,
        guardia_nombre TEXT,
        foto TEXT,
        observaciones TEXT,
        edificio TEXT,
        created_at TEXT NOT NULL,
        sync_status INTEGER DEFAULT 0
      )''');

    await db.execute('''
      CREATE TABLE visitas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        guardia_id INTEGER,
        guardia_nombre TEXT,
        tarjeta TEXT,
        nombre_visita TEXT,
        ci TEXT,
        foto_ci TEXT,
        foto_visitante TEXT,
        depto TEXT,
        autoriza TEXT,
        motivo TEXT,
        cantidad INTEGER,
        vehiculo TEXT,
        placa TEXT,
        gps_lat REAL,
        gps_lng REAL,
        dispositivo TEXT,
        observaciones TEXT,
        hora_salida TEXT,
        estado TEXT DEFAULT 'dentro',
        tarjeta_devuelta INTEGER DEFAULT 0,
        tarjeta_num TEXT,
        edificio TEXT,
        created_at TEXT NOT NULL,
        sync_status INTEGER DEFAULT 0
      )''');

    await db.execute('''
      CREATE TABLE rondas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        guardia_id INTEGER,
        guardia_nombre TEXT,
        gps_lat REAL,
        gps_lng REAL,
        dispositivo TEXT,
        puntos TEXT,
        observaciones TEXT,
        con_novedad INTEGER DEFAULT 0,
        edificio TEXT,
        created_at TEXT NOT NULL,
        sync_status INTEGER DEFAULT 0
      )''');

    await db.execute('''
      CREATE TABLE propietarios (
        id TEXT PRIMARY KEY,
        edificio TEXT,
        torre TEXT,
        depto TEXT,
        copropietario TEXT,
        telefono TEXT,
        inquilino TEXT,
        telefono_inq TEXT,
        mascota TEXT,
        nombre_mascota TEXT,
        nro_parqueo TEXT,
        vehiculo TEXT,
        placa TEXT,
        observaciones TEXT
      )''');

    await db.execute('''
      CREATE TABLE residentes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        edificio TEXT,
        depto TEXT,
        nombre TEXT,
        parentesco TEXT,
        celular TEXT,
        foto TEXT,
        observaciones TEXT
      )''');

    await db.execute('''
      CREATE TABLE vehiculos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        edificio TEXT,
        depto TEXT,
        placa TEXT,
        vehiculo TEXT,
        marca TEXT,
        modelo TEXT,
        color TEXT,
        foto TEXT,
        propietario TEXT,
        nro_parqueo TEXT,
        telefono TEXT,
        observaciones TEXT
      )''');

    await db.execute('''
      CREATE TABLE contactos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        edificio TEXT,
        nombre TEXT,
        telefono TEXT
      )''');

    await db.execute('''
      CREATE TABLE normativas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        edificio TEXT,
        nombre TEXT,
        pdf_path TEXT
      )''');

    // Tablas para expansion futura (Hospedajes, Encomiendas, Incidentes, Mantenimiento)
    await db.execute('''
      CREATE TABLE hospedajes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        guardia_nombre TEXT, plataforma TEXT, huesped TEXT, documento TEXT, foto_doc TEXT,
        depto TEXT, fecha_ingreso TEXT, fecha_salida TEXT, cantidad INTEGER,
        vehiculo TEXT, placa TEXT, observaciones TEXT, estado TEXT DEFAULT 'activo',
        edificio TEXT, created_at TEXT NOT NULL, sync_status INTEGER DEFAULT 0
      )''');
    await db.execute('''
      CREATE TABLE encomiendas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        guardia_nombre TEXT, foto TEXT, depto TEXT, destinatario TEXT, empresa TEXT,
        estado TEXT DEFAULT 'pendiente', foto_entrega TEXT, firma TEXT, hora_entrega TEXT,
        edificio TEXT, created_at TEXT NOT NULL, sync_status INTEGER DEFAULT 0
      )''');
    await db.execute('''
      CREATE TABLE incidentes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        guardia_nombre TEXT, lugar TEXT, tipo TEXT, descripcion TEXT, fotos TEXT,
        involucrados TEXT, estado TEXT DEFAULT 'pendiente',
        edificio TEXT, created_at TEXT NOT NULL, sync_status INTEGER DEFAULT 0
      )''');
    await db.execute('''
      CREATE TABLE mantenimiento (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        lugar TEXT, tipo TEXT, foto_antes TEXT, foto_despues TEXT, observaciones TEXT,
        estado TEXT DEFAULT 'pendiente',
        edificio TEXT, created_at TEXT NOT NULL, sync_status INTEGER DEFAULT 0
      )''');

    await db.execute('''
      CREATE TABLE advertencias (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        guardia_nombre TEXT,
        mensaje TEXT,
        tipo TEXT,
        edificio TEXT,
        created_at TEXT NOT NULL
      )''');

    await db.execute('''
      CREATE TABLE auditoria (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        usuario_id INTEGER,
        usuario_nombre TEXT,
        accion TEXT,
        tabla TEXT,
        registro_id TEXT,
        detalle TEXT,
        dispositivo TEXT,
        created_at TEXT NOT NULL
      )''');
  }

  Future<void> _seed(Database db) async {
    final raw = await rootBundle.loadString('assets/seed/seed.json');
    final data = jsonDecode(raw) as Map<String, dynamic>;

    final batch = db.batch();

    for (final b in (data['buildings'] as List)) {
      batch.insert('edificios', {
        'id': b['id'],
        'nombre': b['nombre'],
        'torres': jsonEncode(b['torres'] ?? []),
        'modulos': jsonEncode(b['modulos'] ?? {}),
        'cant_deptos': 0,
        'cant_pisos': 0,
      });
    }
    for (final x in (data['propietarios'] as List)) {
      batch.insert('propietarios', {
        'id': x['id'], 'edificio': x['edificio'], 'torre': x['torre'], 'depto': x['depto'],
        'copropietario': x['copropietario'], 'telefono': x['telefono'], 'inquilino': x['inquilino'],
        'telefono_inq': x['telefono_inq'], 'mascota': x['mascota'], 'nombre_mascota': x['nombre_mascota'],
        'nro_parqueo': x['nro_parqueo'], 'vehiculo': x['vehiculo'], 'placa': x['placa'],
        'observaciones': x['observaciones'],
      });
    }
    for (final x in (data['residentes'] as List)) {
      batch.insert('residentes', {
        'edificio': x['edificio'], 'depto': x['depto'], 'nombre': x['nombre'],
        'parentesco': x['parentesco'] ?? '', 'celular': x['celular'] ?? '',
      });
    }
    for (final x in (data['vehiculos'] as List)) {
      batch.insert('vehiculos', {
        'edificio': x['edificio'], 'depto': x['depto'], 'placa': x['placa'],
        'vehiculo': x['vehiculo'], 'propietario': x['propietario'], 'nro_parqueo': x['nro_parqueo'],
      });
    }
    for (final x in (data['contactos'] as List)) {
      batch.insert('contactos', {'edificio': x['edificio'], 'nombre': x['nombre'], 'telefono': x['telefono']});
    }
    for (final x in (data['normativas'] as List)) {
      batch.insert('normativas', {'edificio': x['edificio'], 'nombre': x['nombre'], 'pdf_path': ''});
    }

    // Usuario administrador por defecto
    final salt = CryptoUtil.newSalt();
    batch.insert('usuarios', {
      'usuario': 'admin',
      'nombre': 'Administrador',
      'cargo': 'Administrador',
      'rol': 'admin',
      'pass_hash': CryptoUtil.hash('admin123', salt),
      'salt': salt,
      'activo': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    // Usuario guardia de ejemplo
    final salt2 = CryptoUtil.newSalt();
    batch.insert('usuarios', {
      'usuario': 'guardia',
      'nombre': 'Juan Perez',
      'cargo': 'Guardia de Seguridad',
      'rol': 'guardia',
      'pass_hash': CryptoUtil.hash('guardia123', salt2),
      'salt': salt2,
      'activo': 1,
      'created_at': DateTime.now().toIso8601String(),
    });

    await batch.commit(noResult: true);
  }
}
