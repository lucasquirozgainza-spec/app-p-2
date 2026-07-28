import 'dart:io';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../db/database_helper.dart';
import '../services/app_state.dart';

/// Genera un PDF con el informe del periodo y lo abre.
class PdfExport {
  static Future<void> informe({required DateTime desde, required String periodo}) async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final di = desde.toIso8601String();

    Future<List<Map<String, dynamic>>> q(String tabla, [String orden = 'created_at']) async =>
        await db.query(tabla, where: 'edificio=? AND created_at>=?', whereArgs: [ed, di], orderBy: '$orden DESC');

    final visitas = await q('visitas');
    final rondas = await q('rondas');
    final incidentes = await q('incidentes');
    final encomiendas = await q('encomiendas');
    final turnos = await q('ingreso_turno');

    final doc = pw.Document();
    final fecha = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now());

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      build: (ctx) => [
        pw.Header(
          level: 0,
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('CondoControl Pro - Informe', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
            pw.Text('Edificio: ${AppState.instance.edificioNombre}'),
            pw.Text('Periodo: $periodo   ·   Generado: $fecha'),
          ]),
        ),
        pw.SizedBox(height: 10),
        pw.Text('Resumen', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.Table.fromTextArray(
          headers: ['Modulo', 'Cantidad'],
          data: [
            ['Visitas', '${visitas.length}'],
            ['Rondas', '${rondas.length}'],
            ['Incidentes', '${incidentes.length}'],
            ['Encomiendas', '${encomiendas.length}'],
            ['Ingresos de turno', '${turnos.length}'],
          ],
        ),
        pw.SizedBox(height: 16),
        _seccion('Visitas', visitas, (v) =>
            '${_h(v['created_at'])} · ${v['nombre_visita'] ?? ''} · Depto ${v['depto'] ?? ''} · ${v['estado'] ?? ''}'),
        _seccion('Incidentes', incidentes, (v) =>
            '${_h(v['created_at'])} · ${v['tipo'] ?? ''} · ${v['lugar'] ?? ''} · ${v['descripcion'] ?? ''}'),
        _seccion('Rondas', rondas, (v) =>
            '${_h(v['created_at'])} · Guardia ${v['guardia_nombre'] ?? ''}'),
        _seccion('Ingresos de turno', turnos, (v) =>
            '${_h(v['created_at'])} · ${v['guardia_nombre'] ?? ''}'),
      ],
    ));

    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'Informe_${DateTime.now().millisecondsSinceEpoch}.pdf'));
    await file.writeAsBytes(await doc.save());
    await OpenFilex.open(file.path);
  }

  static pw.Widget _seccion(String titulo, List<Map<String, dynamic>> rows, String Function(Map<String, dynamic>) linea) {
    if (rows.isEmpty) return pw.SizedBox();
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.SizedBox(height: 10),
      pw.Text(titulo, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
      pw.Divider(),
      ...rows.take(80).map((r) => pw.Bullet(text: linea(r), style: const pw.TextStyle(fontSize: 10))),
    ]);
  }

  static String _h(Object? iso) {
    try {
      return DateFormat('dd/MM HH:mm').format(DateTime.parse(iso.toString()));
    } catch (_) {
      return '';
    }
  }
}
