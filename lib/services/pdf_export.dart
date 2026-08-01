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

  /// Informe MENSUAL de toda la actividad del edificio.
  static Future<void> informeMensual({required DateTime mes}) async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final desde = DateTime(mes.year, mes.month, 1);
    final hasta = DateTime(mes.year, mes.month + 1, 1);
    final di = desde.toIso8601String(), ha = hasta.toIso8601String();

    Future<List<Map<String, dynamic>>> q(String t) async => db.query(t,
        where: 'edificio=? AND created_at>=? AND created_at<?', whereArgs: [ed, di, ha], orderBy: 'created_at DESC');

    final visitas = await q('visitas');
    final rondas = await q('rondas');
    final incidentes = await q('incidentes');
    final encomiendas = await q('encomiendas');
    final mantenimiento = await q('mantenimiento');
    final hospedajes = await q('hospedajes');
    final turnos = await q('ingreso_turno');

    // Visitas por departamento.
    final porDepto = <String, int>{};
    for (final v in visitas) {
      final d = (v['depto']?.toString().trim().isNotEmpty ?? false) ? v['depto'].toString() : '—';
      porDepto[d] = (porDepto[d] ?? 0) + 1;
    }
    final deptoOrden = porDepto.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    final doc = pw.Document();
    final periodo = DateFormat('MMMM yyyy', 'es').format(mes);
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
        _portada('Informe mensual · $periodo', fecha),
        pw.SizedBox(height: 14),
        _resumen({
          'Visitas': visitas.length,
          'Rondas': rondas.length,
          'Incidentes': incidentes.length,
          'Encomiendas': encomiendas.length,
          'Mantenimiento': mantenimiento.length,
          'Hospedajes': hospedajes.length,
          'Ingresos de turno': turnos.length,
        }),
        _tabla('Visitas por departamento', ['Departamento', 'Total visitas'],
            deptoOrden.map((e) => [e.key, '${e.value}']).toList()),
        _tabla('Incidentes', ['Fecha', 'Tipo', 'Lugar', 'Descripcion', 'Estado'],
            incidentes.map((v) => [_h(v['created_at']), _s(v['tipo']), _s(v['lugar']), _s(v['descripcion']), _s(v['estado'])]).toList()),
        _tabla('Mantenimiento', ['Fecha', 'Lugar', 'Tipo', 'Observaciones', 'Estado'],
            mantenimiento.map((v) => [_h(v['created_at']), _s(v['lugar']), _s(v['tipo']), _s(v['observaciones']), _s(v['estado'])]).toList()),
        _tabla('Encomiendas', ['Fecha', 'Depto', 'Destinatario', 'Empresa', 'Estado'],
            encomiendas.map((v) => [_h(v['created_at']), _s(v['depto']), _s(v['destinatario']), _s(v['empresa']), _s(v['estado'])]).toList()),
        _tabla('Hospedajes', ['Fecha', 'Depto', 'Huesped', 'Plataforma', 'Estado'],
            hospedajes.map((v) => [_h(v['created_at']), _s(v['depto']), _s(v['huesped']), _s(v['plataforma']), _s(v['estado'])]).toList()),
        _tabla('Rondas', ['Fecha', 'Guardia', 'Observaciones'],
            rondas.map((v) => [_h(v['created_at']), _s(v['guardia_nombre']), _s(v['observaciones'])]).toList()),
      ],
    ));

    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'Informe_Mensual_OSIRIS_${DateTime.now().millisecondsSinceEpoch}.pdf'));
    await file.writeAsBytes(await doc.save());
    await Share.shareXFiles([XFile(file.path)], text: 'Informe mensual OSIRIS - ${AppState.instance.edificioNombre} - $periodo');
  }

  /// Reporte MENSUAL de guardias: dias, horas, horas extra (>12h), turnos 24h
  /// y dias sin uniforme.
  static Future<void> reporteGuardias({required DateTime mes}) async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final desde = DateTime(mes.year, mes.month, 1);
    final hasta = DateTime(mes.year, mes.month + 1, 1);
    final di = desde.toIso8601String(), ha = hasta.toIso8601String();

    final ingresos = await db.query('ingreso_turno',
        where: 'edificio=? AND created_at>=? AND created_at<?', whereArgs: [ed, di, ha], orderBy: 'created_at');
    final salidas = await db.query('salida_turno', where: 'edificio=?', whereArgs: [ed]);
    final salMap = <int, String>{};
    for (final s in salidas) {
      if (s['turno_id'] != null) salMap[s['turno_id'] as int] = s['created_at'] as String;
    }
    final advUni = await db.query('advertencias',
        where: "edificio=? AND tipo='uniforme' AND created_at>=? AND created_at<?", whereArgs: [ed, di, ha]);
    final sinUni = <String, int>{};
    for (final a in advUni) {
      final g = a['guardia_nombre']?.toString() ?? 'Sin nombre';
      sinUni[g] = (sinUni[g] ?? 0) + 1;
    }

    final mapa = <String, Map<String, dynamic>>{};
    for (final ing in ingresos) {
      final nombre = ing['guardia_nombre']?.toString() ?? 'Sin nombre';
      final m = mapa.putIfAbsent(nombre, () => {'dias': <String>{}, 'horas': 0.0, 'extra': 0.0, 'turnos': 0, 'dobles': 0});
      final inicio = DateTime.parse(ing['created_at'] as String);
      (m['dias'] as Set).add(DateFormat('yyyy-MM-dd').format(inicio));
      m['turnos'] = (m['turnos'] as int) + 1;
      final salStr = salMap[ing['id']];
      if (salStr != null) {
        final horas = DateTime.parse(salStr).difference(inicio).inMinutes / 60.0;
        if (horas > 0 && horas < 48) {
          m['horas'] = (m['horas'] as double) + horas;
          if (horas >= 20) m['dobles'] = (m['dobles'] as int) + 1;
          if (horas > AppState.horasTurno) m['extra'] = (m['extra'] as double) + (horas - AppState.horasTurno);
        }
      }
    }
    // Incluir guardias que solo tienen advertencias de uniforme.
    for (final g in sinUni.keys) {
      mapa.putIfAbsent(g, () => {'dias': <String>{}, 'horas': 0.0, 'extra': 0.0, 'turnos': 0, 'dobles': 0});
    }
    final filas = mapa.entries.toList()
      ..sort((a, b) => (b.value['horas'] as double).compareTo(a.value['horas'] as double));

    final doc = pw.Document();
    final periodo = DateFormat('MMMM yyyy', 'es').format(mes);
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
        _portada('Reporte de guardias · $periodo', fecha),
        pw.SizedBox(height: 14),
        _tabla('Personal del mes', ['Guardia', 'Dias', 'Horas', 'H. extra', 'Turnos 24h', 'Dias sin uniforme'],
            filas.map((e) => [
              e.key,
              '${(e.value['dias'] as Set).length}',
              (e.value['horas'] as double).toStringAsFixed(1),
              (e.value['extra'] as double).toStringAsFixed(1),
              '${e.value['dobles']}',
              '${sinUni[e.key] ?? 0}',
            ]).toList()),
      ],
    ));

    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'Reporte_Guardias_OSIRIS_${DateTime.now().millisecondsSinceEpoch}.pdf'));
    await file.writeAsBytes(await doc.save());
    await Share.shareXFiles([XFile(file.path)], text: 'Reporte de guardias OSIRIS - ${AppState.instance.edificioNombre} - $periodo');
  }

  /// PDF con los QR de los puntos de control, para imprimir y pegar en cada punto.
  static Future<void> puntosControl(List<Map<String, dynamic>> puntos) async {
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(24),
      build: (ctx) => [
        pw.Text('OSIRIS · Puntos de control de ronda',
            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: _navy)),
        pw.Text('Edificio: ${AppState.instance.edificioNombre}. Pega cada QR en su punto; el guardia lo escanea al pasar.',
            style: const pw.TextStyle(fontSize: 10)),
        pw.SizedBox(height: 14),
        pw.Wrap(
          spacing: 18,
          runSpacing: 18,
          children: [
            for (final p in puntos)
              pw.Container(
                width: 150,
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400)),
                child: pw.Column(children: [
                  pw.BarcodeWidget(
                    barcode: pw.Barcode.qrCode(),
                    data: p['codigo']?.toString() ?? '',
                    width: 120, height: 120,
                  ),
                  pw.SizedBox(height: 8),
                  pw.Text(p['nombre']?.toString() ?? '',
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                ]),
              ),
          ],
        ),
      ],
    ));
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'Puntos_Ronda_OSIRIS_${DateTime.now().millisecondsSinceEpoch}.pdf'));
    await file.writeAsBytes(await doc.save());
    await Share.shareXFiles([XFile(file.path)], text: 'Puntos de control OSIRIS - ${AppState.instance.edificioNombre}');
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
