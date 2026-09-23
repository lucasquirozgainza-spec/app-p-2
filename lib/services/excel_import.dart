import 'dart:io';
import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:sqflite/sqflite.dart';
import '../db/database_helper.dart';

class ImportResultado {
  final int propietarios;
  final int residentes;
  final String? error;
  ImportResultado(this.propietarios, this.residentes, {this.error});
}

/// Importa propietarios (y residentes si hay columnas) desde un Excel para un
/// edificio. Detecta las columnas por su encabezado (depto, nombre, telefono...).
class ExcelImport {
  static String _txt(Data? c) {
    final v = c?.value;
    if (v == null) return '';
    var s = v.toString().trim();
    // Numeros enteros leidos como double (ej. telefono "70012345.0").
    if (RegExp(r'^\d+\.0$').hasMatch(s)) s = s.substring(0, s.length - 2);
    return s;
  }

  static int _col(List<String> header, List<String> claves) {
    for (int i = 0; i < header.length; i++) {
      for (final k in claves) {
        if (header[i].contains(k)) return i;
      }
    }
    return -1;
  }

  /// Lee el Excel EN SEGUNDO PLANO (isolate) y guarda todo en UNA transacción.
  /// Antes se decodificaba en el hilo de la pantalla y se insertaba fila por
  /// fila: con archivos grandes la app se congelaba.
  static Future<ImportResultado> importar(String path, String edificioId) async {
    try {
      final datos = await compute(_leerExcel, <String, String>{'path': path, 'ed': edificioId});
      final props = datos['props']!;
      final resis = datos['res']!;
      final db = await DB.instance.database;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final r in resis) {
          batch.insert('residentes', r);
        }
        for (final pr in props) {
          batch.insert('propietarios', pr, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });
      return ImportResultado(props.length, resis.length);
    } catch (e) {
      return ImportResultado(0, 0, error: e.toString());
    }
  }
}

/// Corre en un isolate: devuelve las filas listas para insertar.
Map<String, List<Map<String, Object?>>> _leerExcel(Map<String, String> args) {
  final edificioId = args['ed']!;
  final bytes = File(args['path']!).readAsBytesSync();
  final ex = Excel.decodeBytes(bytes);
  final props = <Map<String, Object?>>[];
  final resis = <Map<String, Object?>>[];
  final base = DateTime.now().microsecondsSinceEpoch;
  int n = 0;
  for (final tabla in ex.tables.keys) {
    final sheet = ex.tables[tabla];
    if (sheet == null || sheet.rows.isEmpty) continue;
    final rows = sheet.rows;
    final header = rows.first.map((c) => ExcelImport._txt(c).toLowerCase()).toList();

    final iDepto = ExcelImport._col(header, ['depto', 'departa', 'unidad', 'dpto']);
    final iNombre = ExcelImport._col(header, ['copropietario', 'propietario', 'nombre', 'dueñ', 'duen', 'residente']);
    final iTel = ExcelImport._col(header, ['telefono', 'celular', 'whatsapp', 'telf', 'contacto', 'cel']);
    final iInq = ExcelImport._col(header, ['inquilino']);
    final iTelInq = ExcelImport._col(header, ['tel inq', 'cel inq', 'telefono inq', 'inquilino tel']);
    final iParent = ExcelImport._col(header, ['parentesco', 'relacion', 'vinculo']);

    // Si no hay ni depto ni nombre, esta hoja no parece de personas.
    if (iDepto < 0 && iNombre < 0) continue;

    for (int r = 1; r < rows.length; r++) {
      final row = rows[r];
      String cell(int i) => (i >= 0 && i < row.length) ? ExcelImport._txt(row[i]) : '';
      final depto = cell(iDepto);
      final nombre = cell(iNombre);
      final tel = cell(iTel);
      if (depto.isEmpty && nombre.isEmpty) continue;

      // Si la hoja tiene columna de parentesco, se trata como residentes.
      if (iParent >= 0 && cell(iParent).isNotEmpty) {
        resis.add({
          'edificio': edificioId,
          'depto': depto,
          'nombre': nombre,
          'parentesco': cell(iParent),
          'celular': tel,
        });
      } else {
        props.add({
          'id': 'imp_${edificioId}_${base}_${n++}',
          'edificio': edificioId,
          'torre': '',
          'depto': depto,
          'copropietario': nombre,
          'telefono': tel,
          'inquilino': cell(iInq),
          'telefono_inq': cell(iTelInq),
        });
      }
    }
  }
  return {'props': props, 'res': resis};
}
