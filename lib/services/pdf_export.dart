import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';

/// Genera un informe PDF profesional del periodo y lo comparte/guarda.
class PdfExport {
  static final _rojo = PdfColor.fromInt(0xFFC62828);
  static final _navy = PdfColor.fromInt(0xFF0A335D);
  static final _gris = PdfColor.fromInt(0xFFEFEFEF);

  static Future<void> informe({required DateTime desde, required String periodo}) async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final di = desde.toIso8601String();

    Future<List<Map<String, dynamic>>> q(String tabla) async =>
        db.query(tabla, where: 'edificio=? AND created_at>=?', whereArgs: [ed, di], orderBy: 'created_at DESC');

    final visitas = await q('visitas');
    final rondas = await q('rondas');
    final incidentes = await q('incidentes');
    final encomiendas = await q('encomiendas');
    final turnos = await q('ingreso_turno');
    final mantenimiento = await q('mantenimiento');

    final doc = pw.Document();
    final fecha = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now());

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      header: (ctx) => ctx.pageNumber == 1 ? pw.SizedBox() : _miniHeader(),
      footer: (ctx) => pw.Container(
        alignment: pw.Alignment.centerRight,
        margin: const pw.EdgeInsets.only(top: 8),
        child: pw.Text('OSIRIS Seguridad  ·  Pagina ${ctx.pageNumber}/${ctx.pagesCount}',
            style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
      ),
      build: (ctx) => [
        _portada(periodo, fecha),
        pw.SizedBox(height: 14),
        _resumen({
          'Visitas': visitas.length,
          'Rondas': rondas.length,
          'Incidentes': incidentes.length,
          'Encomiendas': encomiendas.length,
          'Ingresos de turno': turnos.length,
          'Mantenimiento': mantenimiento.length,
        }),
        pw.SizedBox(height: 16),
        _tabla('Visitas', ['Fecha', 'Visitante', 'CI', 'Depto', 'Autoriza', 'Tarjeta', 'Estado'],
            visitas.map((v) => [
              _h(v['created_at']), _s(v['nombre_visita']), _s(v['ci']), _s(v['depto']),
              _s(v['autoriza']), _s(v['tarjeta_num']),
              v['estado'] == 'dentro' ? 'Dentro' : 'Salio',
            ]).toList()),
        _tabla('Incidentes', ['Fecha', 'Tipo', 'Lugar', 'Descripcion', 'Estado'],
            incidentes.map((v) => [
              _h(v['created_at']), _s(v['tipo']), _s(v['lugar']), _s(v['descripcion']), _s(v['estado']),
            ]).toList()),
        _tabla('Rondas', ['Fecha', 'Guardia', 'Fotos', 'Observaciones'],
            rondas.map((v) => [
              _h(v['created_at']), _s(v['guardia_nombre']), _fotosCount(v), _s(v['observaciones']),
            ]).toList()),
        _tabla('Encomiendas', ['Fecha', 'Depto', 'Destinatario', 'Empresa', 'Estado'],
            encomiendas.map((v) => [
              _h(v['created_at']), _s(v['depto']), _s(v['destinatario']), _s(v['empresa']), _s(v['estado']),
            ]).toList()),
        _tabla('Ingresos de turno', ['Fecha', 'Guardia', 'Cargo', 'Bateria'],
            turnos.map((v) => [
              _h(v['created_at']), _s(v['guardia_nombre']), _s(v['cargo']),
              v['bateria'] != null ? '${v['bateria']}%' : '',
            ]).toList()),
      ],
    ));

    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'Informe_OSIRIS_${DateTime.now().millisecondsSinceEpoch}.pdf'));
    await file.writeAsBytes(await doc.save());
    await Share.shareXFiles([XFile(file.path)], text: 'Informe OSIRIS - ${AppState.instance.edificioNombre}');
  }

  /// Informe PDF solo de advertencias (descargable/compartible).
  static Future<void> advertencias() async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final rows = await db.query('advertencias',
        where: 'edificio=?', whereArgs: [ed], orderBy: 'created_at DESC');

    final doc = pw.Document();
    final fecha = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now());
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      header: (ctx) => ctx.pageNumber == 1 ? pw.SizedBox() : _miniHeader(),
      footer: (ctx) => pw.Container(
        alignment: pw.Alignment.centerRight,
        margin: const pw.EdgeInsets.only(top: 8),
        child: pw.Text('OSIRIS Seguridad  ·  Pagina ${ctx.pageNumber}/${ctx.pagesCount}',
            style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
      ),
      build: (ctx) => [
        _portada('Advertencias', fecha),
        pw.SizedBox(height: 14),
        _tabla('Advertencias', ['Fecha', 'Tipo', 'Guardia', 'Detalle'],
            rows.map((v) => [
              _h(v['created_at']), _s(v['tipo']), _s(v['guardia_nombre']), _s(v['mensaje']),
            ]).toList()),
        if (rows.isEmpty)
          pw.Padding(padding: const pw.EdgeInsets.only(top: 20),
              child: pw.Text('No hay advertencias registradas.')),
      ],
    ));

    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'Advertencias_OSIRIS_${DateTime.now().millisecondsSinceEpoch}.pdf'));
    await file.writeAsBytes(await doc.save());
    await Share.shareXFiles([XFile(file.path)], text: 'Advertencias OSIRIS - ${AppState.instance.edificioNombre}');
  }

  static pw.Widget _portada(String periodo, String fecha) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(16),
      decoration: pw.BoxDecoration(
        gradient: pw.LinearGradient(colors: [_navy, PdfColor.fromInt(0xFF1E6FB8)]),
        borderRadius: pw.BorderRadius.circular(10),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Container(
            width: 46, height: 46,
            decoration: pw.BoxDecoration(color: _rojo, borderRadius: pw.BorderRadius.circular(10)),
            alignment: pw.Alignment.center,
            child: pw.Text('O', style: pw.TextStyle(color: PdfColors.white, fontSize: 26, fontWeight: pw.FontWeight.bold)),
          ),
          pw.SizedBox(width: 14),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('OSIRIS Seguridad', style: pw.TextStyle(color: PdfColors.white, fontSize: 22, fontWeight: pw.FontWeight.bold)),
            pw.Text('Informe de gestion', style: const pw.TextStyle(color: PdfColors.white, fontSize: 13)),
            pw.SizedBox(height: 4),
            pw.Text('Edificio: ${AppState.instance.edificioNombre}   ·   Periodo: $periodo',
                style: const pw.TextStyle(color: PdfColors.white, fontSize: 10)),
            pw.Text('Generado: $fecha', style: const pw.TextStyle(color: PdfColors.white, fontSize: 10)),
          ]),
        ],
      ),
    );
  }

  static pw.Widget _miniHeader() => pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Text('OSIRIS Seguridad - Informe',
            style: pw.TextStyle(color: _navy, fontSize: 11, fontWeight: pw.FontWeight.bold)),
      );

  static pw.Widget _resumen(Map<String, int> datos) {
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _titulo('Resumen del periodo'),
      pw.SizedBox(height: 6),
      pw.Wrap(spacing: 8, runSpacing: 8, children: [
        for (final e in datos.entries)
          pw.Container(
            width: 150,
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(color: _gris, borderRadius: pw.BorderRadius.circular(8)),
            child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text(e.key, style: const pw.TextStyle(fontSize: 10)),
              pw.Text('${e.value}', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: _rojo)),
            ]),
          ),
      ]),
    ]);
  }

  static pw.Widget _tabla(String titulo, List<String> headers, List<List<String>> data) {
    if (data.isEmpty) return pw.SizedBox();
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.SizedBox(height: 14),
      _titulo('$titulo (${data.length})'),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headers: headers,
        data: data,
        headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 8.5),
        headerDecoration: pw.BoxDecoration(color: _navy),
        cellStyle: const pw.TextStyle(fontSize: 8),
        cellHeight: 16,
        cellAlignment: pw.Alignment.centerLeft,
        oddRowDecoration: pw.BoxDecoration(color: PdfColor.fromInt(0xFFF6F8FA)),
        border: pw.TableBorder.all(color: PdfColors.grey300, width: .5),
      ),
    ]);
  }

  static pw.Widget _titulo(String t) => pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: pw.BoxDecoration(
          border: pw.Border(left: pw.BorderSide(color: _rojo, width: 3)),
        ),
        child: pw.Text(t, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: _navy)),
      );

  static String _s(Object? v) {
    final s = v?.toString() ?? '';
    return s.length > 60 ? '${s.substring(0, 60)}...' : s;
  }

  static String _h(Object? iso) {
    try {
      return DateFormat('dd/MM HH:mm').format(DateTime.parse(iso.toString()));
    } catch (_) {
      return '';
    }
  }

  static String _fotosCount(Map<String, dynamic> v) {
    try {
      final s = v['puntos']?.toString() ?? '';
      final m = RegExp(r'IMG_').allMatches(s).length;
      return '$m fotos';
    } catch (_) {
      return '';
    }
  }
}
