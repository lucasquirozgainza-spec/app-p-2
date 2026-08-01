import '../db/database_helper.dart';
import 'app_state.dart';

/// Contacto de un departamento (propietario, inquilino o residente).
class ContactoDepto {
  final String nombre;
  final String tel;
  final String rol;
  ContactoDepto(this.nombre, this.tel, this.rol);
}

/// Busca las personas registradas para un departamento del edificio actual.
class ContactosRepo {
  static Future<List<ContactoDepto>> delDepto(String depto) async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final d = depto.trim();
    if (d.isEmpty) return [];
    final out = <ContactoDepto>[];
    final props = await db.query('propietarios', where: 'edificio=? AND depto=?', whereArgs: [ed, d]);
    for (final p in props) {
      final cop = p['copropietario']?.toString() ?? '';
      if (cop.isNotEmpty) out.add(ContactoDepto(cop, p['telefono']?.toString() ?? '', 'Propietario'));
      final inq = p['inquilino']?.toString() ?? '';
      if (inq.isNotEmpty) out.add(ContactoDepto(inq, p['telefono_inq']?.toString() ?? '', 'Inquilino'));
    }
    final resis = await db.query('residentes', where: 'edificio=? AND depto=?', whereArgs: [ed, d]);
    for (final r in resis) {
      out.add(ContactoDepto(r['nombre']?.toString() ?? '', r['celular']?.toString() ?? '', 'Residente'));
    }
    return out;
  }

  /// Encargado (contacto predeterminado) del departamento, si se marcó uno.
  static Future<ContactoDepto?> encargado(String depto) async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final rows = await db.query('encargados',
        where: 'edificio=? AND depto=?', whereArgs: [ed, depto.trim()], limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return ContactoDepto(r['nombre']?.toString() ?? '', r['telefono']?.toString() ?? '', 'Encargado');
  }

  /// Marca a una persona como encargada del departamento (contacto predeterminado).
  static Future<void> setEncargado(String depto, String nombre, String tel) async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    await db.delete('encargados', where: 'edificio=? AND depto=?', whereArgs: [ed, depto.trim()]);
    await db.insert('encargados', {'edificio': ed, 'depto': depto.trim(), 'nombre': nombre, 'telefono': tel});
  }

  /// Lista de deptos distintos para autocompletar (propietarios + residentes).
  static Future<List<String>> deptos([String filtro = '']) async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final f = filtro.trim();
    final where = f.isEmpty ? 'edificio=?' : 'edificio=? AND depto LIKE ?';
    final args = f.isEmpty ? [ed] : [ed, '$f%'];
    final a = await db.rawQuery('SELECT DISTINCT depto FROM propietarios WHERE $where', args);
    final b = await db.rawQuery('SELECT DISTINCT depto FROM residentes WHERE $where', args);
    final set = <String>{};
    for (final r in [...a, ...b]) {
      final d = r['depto']?.toString().trim() ?? '';
      if (d.isNotEmpty) set.add(d);
    }
    final list = set.toList()..sort();
    return list;
  }
}
