import 'dart:io';
import 'package:excel/excel.dart';
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

  static Future<ImportResultado> importar(String path, String edificioId) async {
    try {
      final bytes = File(path).readAsBytesSync();
      final ex = Excel.decodeBytes(bytes);
      final db = await DB.instance.database;
      int nProp = 0, nRes = 0;

      for (final tabla in ex.tables.keys) {
        final sheet = ex.tables[tabla];
        if (sheet == null || sheet.rows.isEmpty) continue;
        final rows = sheet.rows;
        final header = rows.first.map((c) => _txt(c).toLowerCase()).toList();

        final iDepto = _col(header, ['depto', 'departa', 'unidad', 'dpto']);
        final iNombre = _col(header, ['copropietario', 'propietario', 'nombre', 'dueñ', 'duen', 'residente']);
        final iTel = _col(header, ['telefono', 'celular', 'whatsapp', 'telf', 'contacto', 'cel']);
        final iInq = _col(header, ['inquilino']);
        final iTelInq = _col(header, ['tel inq', 'cel inq', 'telefono inq', 'inquilino tel']);
        final iParent = _col(header, ['parentesco', 'relacion', 'vinculo']);

        // Si no hay ni depto ni nombre, esta hoja no parece de personas.
        if (iDepto < 0 && iNombre < 0) continue;

        for (int r = 1; r < rows.length; r++) {
          final row = rows[r];
          String cell(int i) => (i >= 0 && i < row.length) ? _txt(row[i]) : '';
          final depto = cell(iDepto);
          final nombre = cell(iNombre);
          final tel = cell(iTel);
          if (depto.isEmpty && nombre.isEmpty) continue;

          // Si la hoja tiene columna de parentesco, se trata como residentes.
          if (iParent >= 0 && cell(iParent).isNotEmpty) {
            await db.insert('residentes', {
              'edificio': edificioId,
              'depto': depto,
              'nombre': nombre,
              'parentesco': cell(iParent),
              'celular': tel,
            });
            nRes++;
          } else {
            final id = 'imp_${edificioId}_${DateTime.now().microsecondsSinceEpoch}_$r';
            await db.insert('propietarios', {
              'id': id,
              'edificio': edificioId,
              'torre': '',
              'depto': depto,
              'copropietario': nombre,
              'telefono': tel,
              'inquilino': cell(iInq),
              'telefono_inq': cell(iTelInq),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
            nProp++;
          }
        }
      }
      return ImportResultado(nProp, nRes);
    } catch (e) {
      return ImportResultado(0, 0, error: e.toString());
    }
  }
}
