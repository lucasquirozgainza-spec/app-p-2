import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/turnos.dart';
import '../services/panel_horas.dart';
import '../services/horas_local.dart';
import '../services/guardias_service.dart';
import '../services/cloud.dart';
import '../widgets/evento_tile.dart';

/// Construye el PDF de actividad en un ISOLATE aparte (compute), para que la
/// interfaz NUNCA se congele aunque haya cientos de filas. Recibe datos ya
/// convertidos a texto (nada de AppState ni canales de plataforma aquí).
Future<Uint8List> _actividadPdfBytes(Map<String, dynamic> args) async {
  final titulo = args['titulo'] as String;
  final fecha = args['fecha'] as String;
  final total = args['total'] as int;
  final recortado = args['recortado'] as bool;
  final maxFilas = args['maxFilas'] as int;
  final rows = (args['rows'] as List).map((r) => (r as List).cast<String>()).toList();
  final logo = args['logo'] as Uint8List?;

  final navy = PdfColor.fromInt(0xFF0A335D);
  final rojo = PdfColor.fromInt(0xFFC62828);

  final doc = pw.Document();
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(24),
    header: (ctx) => ctx.pageNumber == 1
        ? pw.SizedBox()
        : pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 8),
            child: pw.Text('OSIRIS Seguridad - Actividad',
                style: pw.TextStyle(color: navy, fontSize: 11, fontWeight: pw.FontWeight.bold))),
    footer: (ctx) => pw.Container(
      alignment: pw.Alignment.centerRight,
      margin: const pw.EdgeInsets.only(top: 8),
      child: pw.Text('OSIRIS Seguridad  -  Pagina ${ctx.pageNumber}/${ctx.pagesCount}',
          style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
    ),
    build: (ctx) => [
      // Portada simple (sin AppState, para poder correr en el isolate).
      pw.Container(
        padding: const pw.EdgeInsets.all(16),
        decoration: pw.BoxDecoration(
          gradient: pw.LinearGradient(colors: [navy, PdfColor.fromInt(0xFF1E6FB8)]),
          borderRadius: pw.BorderRadius.circular(10),
        ),
        child: pw.Row(children: [
          if (logo != null)
            pw.Container(
              width: 60, height: 60,
              padding: const pw.EdgeInsets.all(6),
              decoration: pw.BoxDecoration(color: PdfColors.white, borderRadius: pw.BorderRadius.circular(10)),
              child: pw.Image(pw.MemoryImage(logo), fit: pw.BoxFit.contain),
            )
          else
            pw.Container(
              width: 46, height: 46,
              decoration: pw.BoxDecoration(color: rojo, borderRadius: pw.BorderRadius.circular(10)),
              alignment: pw.Alignment.center,
              child: pw.Text('O', style: pw.TextStyle(color: PdfColors.white, fontSize: 26, fontWeight: pw.FontWeight.bold)),
            ),
          pw.SizedBox(width: 14),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('OSIRIS Seguridad', style: pw.TextStyle(color: PdfColors.white, fontSize: 22, fontWeight: pw.FontWeight.bold)),
            pw.Text('Actividad: $titulo', style: const pw.TextStyle(color: PdfColors.white, fontSize: 12)),
            pw.Text('Generado: $fecha', style: const pw.TextStyle(color: PdfColors.white, fontSize: 10)),
          ]),
        ]),
      ),
      pw.SizedBox(height: 14),
      if (recortado)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 8),
          child: pw.Text('Mostrando los $maxFilas registros mas recientes de $total.',
              style: pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        ),
      if (rows.isEmpty)
        pw.Padding(padding: const pw.EdgeInsets.only(top: 20), child: pw.Text('No hay actividad en la nube.'))
      else
        pw.TableHelper.fromTextArray(
          headers: const ['Fecha', 'Tipo', 'Guardia', 'Edificio', 'Detalle'],
          data: rows,
          headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 8.5),
          headerDecoration: pw.BoxDecoration(color: navy),
          cellStyle: const pw.TextStyle(fontSize: 8),
          cellHeight: 16,
          cellAlignment: pw.Alignment.centerLeft,
          columnWidths: {
            0: const pw.FlexColumnWidth(1.6),
            1: const pw.FlexColumnWidth(1.6),
            2: const pw.FlexColumnWidth(1.8),
            3: const pw.FlexColumnWidth(1.6),
            4: const pw.FlexColumnWidth(3.4),
          },
          oddRowDecoration: pw.BoxDecoration(color: PdfColor.fromInt(0xFFF6F8FA)),
          border: pw.TableBorder.all(color: PdfColors.grey300, width: .5),
        ),
    ],
  ));
  return doc.save();
}

/// Informe genérico armado en un ISOLATE (no congela la app): portada y
/// bloques de texto o tablas con datos simples (solo textos).
Future<Uint8List> _informePdfBytes(Map<String, dynamic> args) async {
  final titulo = args['titulo'] as String;
  final fecha = args['fecha'] as String;
  final logo = args['logo'] as Uint8List?;
  final bloques = (args['bloques'] as List).cast<Map>();
  final navy = PdfColor.fromInt(0xFF0A335D);
  final rojo = PdfColor.fromInt(0xFFC62828);
  final gris = PdfColor.fromInt(0xFFEFEFEF);

  final cuerpo = <pw.Widget>[
    pw.Container(
      padding: const pw.EdgeInsets.all(14),
      decoration: pw.BoxDecoration(
        gradient: pw.LinearGradient(colors: [navy, PdfColor.fromInt(0xFF1E6FB8)]),
        borderRadius: pw.BorderRadius.circular(10),
      ),
      child: pw.Row(children: [
        if (logo != null)
          pw.Container(
            width: 52, height: 52,
            padding: const pw.EdgeInsets.all(5),
            decoration: pw.BoxDecoration(color: PdfColors.white, borderRadius: pw.BorderRadius.circular(10)),
            child: pw.Image(pw.MemoryImage(logo), fit: pw.BoxFit.contain),
          ),
        pw.SizedBox(width: 12),
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('OSIRIS Seguridad', style: pw.TextStyle(color: PdfColors.white, fontSize: 18, fontWeight: pw.FontWeight.bold)),
            pw.Text(titulo, style: const pw.TextStyle(color: PdfColors.white, fontSize: 12)),
            pw.Text('Generado: $fecha', style: const pw.TextStyle(color: PdfColors.white, fontSize: 9)),
          ]),
        ),
      ]),
    ),
  ];
  for (final b in bloques) {
    final t = b['titulo'] as String?;
    if (t != null && t.isNotEmpty) {
      cuerpo.add(pw.SizedBox(height: 12));
      cuerpo.add(pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: pw.BoxDecoration(border: pw.Border(left: pw.BorderSide(color: rojo, width: 3))),
        child: pw.Text(t, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: navy)),
      ));
    }
    final texto = b['texto'] as String?;
    if (texto != null && texto.isNotEmpty) {
      cuerpo.add(pw.Padding(
        padding: const pw.EdgeInsets.only(top: 4),
        child: pw.Text(texto, style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700)),
      ));
    }
    final headers = (b['headers'] as List?)?.cast<String>();
    final rows = (b['rows'] as List?)?.map((r) => (r as List).cast<String>()).toList();
    if (headers != null && rows != null) {
      if (rows.isEmpty) {
        cuerpo.add(pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Text('Sin registros', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600))));
      } else {
        cuerpo.add(pw.SizedBox(height: 4));
        cuerpo.add(pw.TableHelper.fromTextArray(
          headers: headers,
          data: rows,
          headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 8.5),
          headerDecoration: pw.BoxDecoration(color: navy),
          cellStyle: const pw.TextStyle(fontSize: 8),
          oddRowDecoration: pw.BoxDecoration(color: gris),
          cellAlignment: pw.Alignment.centerLeft,
          border: pw.TableBorder.all(color: PdfColors.grey300, width: .5),
        ));
      }
    }
  }
  final doc = pw.Document();
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(24),
    maxPages: 400,
    footer: (ctx) => pw.Container(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('OSIRIS Seguridad  -  Pagina ${ctx.pageNumber}/${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
    ),
    build: (_) => cuerpo,
  ));
  return doc.save();
}

/// Genera un informe PDF profesional del periodo y lo comparte/guarda.
class PdfExport {
  static final _rojo = PdfColor.fromInt(0xFFC62828);
  static final _navy = PdfColor.fromInt(0xFF0A335D);
  static final _gris = PdfColor.fromInt(0xFFEFEFEF);

  // Logo OSIRIS para los PDF (se carga una vez desde assets).
  static Uint8List? _logoBytes;
  static bool _logoTried = false;
  static Future<Uint8List?> _ensureLogo() async {
    if (_logoTried) return _logoBytes;
    _logoTried = true;
    try {
      _logoBytes = (await rootBundle.load('assets/osiris_logo.png')).buffer.asUint8List();
    } catch (_) {
      _logoBytes = null;
    }
    return _logoBytes;
  }

  static Future<void> informe({required DateTime desde, required String periodo}) async {
    await _ensureLogo();
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
    await _ensureLogo();
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
    await _ensureLogo();
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

  /// Arma el PDF en un isolate (la app no se congela), lo guarda y lo comparte.
  static Future<void> _informe({
    required String titulo,
    required List<Map<String, dynamic>> bloques,
    required String archivo,
    required String textoCompartir,
  }) async {
    final logo = await _ensureLogo();
    // Celdas limitadas: una celda enorme no entra en una página y trababa el PDF.
    String corta(String x) => x.length > 140 ? '${x.substring(0, 140)}...' : x;
    final limpios = [
      for (final b in bloques)
        {
          if (b['titulo'] != null) 'titulo': _safe('${b['titulo']}'),
          if (b['texto'] != null) 'texto': _safe('${b['texto']}'),
          if (b['headers'] != null) 'headers': [for (final h in (b['headers'] as List)) _safe('$h')],
          if (b['rows'] != null)
            'rows': [
              for (final r in (b['rows'] as List).take(1500)) [for (final c in (r as List)) corta(_safe('$c'))]
            ],
        }
    ];
    final bytes = await compute(_informePdfBytes, <String, dynamic>{
      'titulo': _safe(titulo),
      'fecha': DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now()),
      'logo': logo,
      'bloques': limpios,
    });
    final dir = await getApplicationDocumentsDirectory();
    final nombre = archivo.replaceAll(RegExp(r'[^A-Za-z0-9_]+'), '_');
    final file = File(p.join(dir.path, '${nombre}_${DateTime.now().millisecondsSinceEpoch}.pdf'));
    await file.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(file.path)], text: textoCompartir);
  }

  static List<String> _filaTurno(RegistroTurno t, {bool conGuardia = false}) {
    final dhm = DateFormat('dd/MM HH:mm');
    return [
      if (conGuardia) t.guardia,
      DateFormat('EEE dd/MM', 'es').format(t.inicio),
      dhm.format(t.inicio),
      t.fin == null ? '-' : dhm.format(t.fin!),
      t.valido ? '${t.nivel} h' : t.estado,
      t.cerrado ? t.horas.toStringAsFixed(1) : '-',
      t.movimientos.isEmpty ? '0' : Turnos.saldo(t.saldo),
      [for (final m in t.movimientos) '${Turnos.saldo(m.horas)} ${m.motivo}${m.con != null ? ' (${m.con})' : ''}']
          .join('; '),
    ];
  }

  /// Reporte MENSUAL de guardias: días, horas, extras (a favor / en
  /// contra), turnos de 24 y 36 h y días sin uniforme.
  static Future<void> reporteGuardias({required DateTime mes}) async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final di = DateTime(mes.year, mes.month).toIso8601String();
    final ha = DateTime(mes.year, mes.month + 1).toIso8601String();
    final advUni = await db.query('advertencias',
        where: "edificio=? AND tipo='uniforme' AND created_at>=? AND created_at<?", whereArgs: [ed, di, ha]);
    final sinUni = <String, int>{};
    for (final a in advUni) {
      final g = a['guardia_nombre']?.toString() ?? 'Sin nombre';
      sinUni[g] = (sinUni[g] ?? 0) + 1;
    }
    // Mismo cálculo que la pantalla Guardias (PanelHoras).
    final horas = await HorasPanel.edificio(mes);
    final filas = PanelHoras.porGuardia(horas.puestos).values.toList()..sort((a, b) => b.horas.compareTo(a.horas));
    final periodo = DateFormat('MMMM yyyy', 'es').format(mes);
    await _informe(
      titulo: 'Reporte de guardias · ${AppState.instance.edificioNombre} · $periodo',
      archivo: 'Reporte_Guardias',
      textoCompartir: 'Reporte de guardias OSIRIS - ${AppState.instance.edificioNombre} - $periodo',
      bloques: [
        if (horas.local && !AppState.instance.soloLocal)
          {'texto': 'Sin conexion al generar: solo incluye los turnos registrados en este celular.'},
        {
          'titulo': 'Personal del mes',
          'headers': ['Guardia', 'ID (CI)', 'Dias', 'Horas', 'Horas extras', '24 h', '36 h', 'Sin uniforme'],
          'rows': [
            for (final r in filas)
              [
                r.guardia,
                r.clave == r.guardia ? '-' : r.clave,
                '${r.dias}',
                r.horas.toStringAsFixed(1),
                Turnos.saldo(r.saldo),
                '${r.n24}',
                '${r.n36}',
                '${sinUni[r.guardia] ?? 0}',
              ],
          ],
        },
        {'texto': _reglaHoras(AppState.instance.toleranciaMin)},
      ],
    );
  }

  /// Reporte detallado de INGRESOS y SALIDAS del mes (mismo cálculo).
  static Future<void> reporteIngresoSalida({required DateTime mes}) async {
    final horas = await HorasPanel.edificio(mes);
    final turnos = [for (final p in horas.puestos) ...p.turnos]..sort((a, b) => a.inicio.compareTo(b.inicio));
    final periodo = DateFormat('MMMM yyyy', 'es').format(mes);
    await _informe(
      titulo: 'Ingresos y salidas · ${AppState.instance.edificioNombre} · $periodo',
      archivo: 'Ingresos_Salidas',
      textoCompartir: 'Ingresos y salidas OSIRIS - ${AppState.instance.edificioNombre} - $periodo',
      bloques: [
        {'texto': 'Relevos: ${AppState.instance.horarios.join(' y ')}. ${_reglaHoras(AppState.instance.toleranciaMin)}'},
        {
          'titulo': 'Detalle de turnos',
          'headers': ['Guardia', 'Dia', 'Ingreso', 'Salida', 'Turno', 'Horas', 'Saldo', 'Origen'],
          'rows': [for (final t in turnos) _filaTurno(t, conGuardia: true)],
        },
      ],
    );
  }

  /// Genera el PDF de actividad y devuelve la RUTA del archivo (no comparte).
  /// El armado pesado corre en un isolate (compute) para no congelar la app.
  static Future<String> actividadNube(List<Map<String, dynamic>> eventos, String titulo) async {
    String detalleStr(dynamic d) {
      if (d is Map) {
        return d.entries
            .where((e) => '${e.value}'.trim().isNotEmpty && e.key != 'ubicacion' && e.key != 'foto_url' && e.key != 'fotos_url')
            .map((e) => '${e.key}: ${e.value}')
            .join(', ');
      }
      return '${d ?? ''}';
    }

    // Preparamos las filas (texto) en el hilo principal — es liviano — y el
    // armado/guardado del PDF se hace en un isolate.
    const maxFilas = 800;
    final total = eventos.length;
    final recortado = total > maxFilas;
    final fuente = recortado ? eventos.sublist(0, maxFilas) : eventos;
    final rows = <List<String>>[];
    for (final e in fuente) {
      var det = _safe(detalleStr(e['detalle']));
      if (det.length > 90) det = '${det.substring(0, 90)}...';
      rows.add([_h(e['created_at']), _s(e['tipo']), _s(e['guardia']), _s(e['edificio']), det]);
    }

    final logo = await _ensureLogo();
    final bytes = await compute(_actividadPdfBytes, <String, dynamic>{
      'titulo': _safe(titulo),
      'fecha': DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now()),
      'rows': rows,
      'total': total,
      'recortado': recortado,
      'maxFilas': maxFilas,
      'logo': logo,
    });

    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'Actividad_OSIRIS_${DateTime.now().millisecondsSinceEpoch}.pdf'));
    await file.writeAsBytes(bytes);
    return file.path;
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

  /// Panel de horas del edificio activo (misma fuente que la pantalla).
  static Future<void> panelHorasLocal({required DateTime mes}) async {
    final horas = await HorasPanel.edificio(mes);
    await panelHoras(
        nota: horas.local && !AppState.instance.soloLocal
            ? 'Sin conexion al generar: solo incluye los turnos registrados en este celular.'
            : null,
        porEdificio: {AppState.instance.edificioNombre: horas.puestos},
        periodo: DateFormat('MMMM yyyy', 'es').format(mes));
  }

  /// PDF de UN guardia: datos, horas del mes, ingresos y salidas, rondas,
  /// incidentes, visitas y advertencias.
  static Future<void> guardiaPdf({
    required Guardia g,
    required String periodo,
    ResumenGuardia? resumen,
    List<Map<String, dynamic>> registros = const [],
  }) async {
    final r = resumen ?? ResumenGuardia(g.nombre, g.ci);
    final turnos = r.turnos.toList()..sort((a, b) => a.inicio.compareTo(b.inicio));
    List<List<String>> filas(Iterable<Map<String, dynamic>> l) => [
          for (final e in l)
            [
              Cloud.horaEvento(e) == null ? '' : DateFormat('dd/MM HH:mm').format(Cloud.horaEvento(e)!),
              '${e['tipo'] ?? ''}',
              resumenEvento(e),
            ]
        ];
    Iterable<Map<String, dynamic>> de(Set<String> tipos) => registros.where((e) => tipos.contains(e['tipo']));
    await _informe(
      titulo: '${g.nombre} · ID ${g.ci} · $periodo',
      archivo: 'Guardia_${g.nombre}',
      textoCompartir: 'OSIRIS - ${g.nombre} (${g.ci}) - $periodo',
      bloques: [
        {
          'titulo': 'Datos del guardia',
          'headers': ['Nombre', 'ID (CI)', 'Edificio', 'Bloque', 'Turno', 'Estado'],
          'rows': [
            [g.nombre, g.ci, g.edificio, g.bloque.isEmpty ? '-' : g.bloque, g.turnoTexto, g.activo ? 'Activo' : 'De baja'],
          ],
        },
        {
          'titulo': 'Horas del mes',
          'headers': ['Dias', 'Horas', 'Horas extras', 'A favor', 'En contra', '24 h', '36 h'],
          'rows': [
            [
              '${r.dias}',
              r.horas.toStringAsFixed(1),
              Turnos.saldo(r.saldo),
              _hm(r.aFavor),
              _hm(r.enContra),
              '${r.n24}',
              '${r.n36}',
            ],
          ],
        },
        {
          'titulo': 'Ingresos y salidas',
          'headers': ['Dia', 'Ingreso', 'Salida', 'Turno', 'Horas', 'Saldo', 'Origen'],
          'rows': [for (final t in turnos) _filaTurno(t)],
        },
        {'titulo': 'Rondas', 'headers': ['Fecha', 'Tipo', 'Detalle'], 'rows': filas(de({'Ronda'}))},
        {'titulo': 'Incidentes', 'headers': ['Fecha', 'Tipo', 'Detalle'], 'rows': filas(de({'Incidente'}))},
        {'titulo': 'Visitas', 'headers': ['Fecha', 'Tipo', 'Detalle'], 'rows': filas(de({'Visita'}))},
        {
          'titulo': 'Advertencias',
          'headers': ['Fecha', 'Tipo', 'Detalle'],
          'rows': filas(de({'Advertencia', 'Guardia sin uniforme'})),
        },
        {'texto': _reglaHoras(AppState.instance.toleranciaMin)},
      ],
    );
  }

  /// PANEL DE HORAS del mes: saldo de cada guardia, cuenta entre los que se
  /// relevan y el detalle día por día.
  static Future<void> panelHoras({
    required Map<String, List<PanelPuesto>> porEdificio,
    required String periodo,
    String? nota,
  }) async {
    String h1(double v) => v.toStringAsFixed(1);
    final bloques = <Map<String, dynamic>>[
      {'texto': _reglaHoras(AppState.instance.toleranciaMin)},
      if (nota != null) {'texto': nota},
    ];
    for (final ed in porEdificio.entries) {
      final todos = PanelHoras.porGuardia(ed.value).values.toList()
        ..sort((a, b) {
          final c = b.saldo.compareTo(a.saldo);
          return c != 0 ? c : a.guardia.compareTo(b.guardia);
        });
      bloques.add({
        'titulo': '${ed.key} - Saldo de horas',
        'headers': ['Guardia', 'Dias', '12 h', '24 h', '36 h', 'Horas', 'A favor', 'En contra', 'Saldo'],
        'rows': [
          for (final r in todos)
            [r.guardia, '${r.dias}', '${r.n12}', '${r.n24}', '${r.n36}', h1(r.horas), _hm(r.aFavor), _hm(r.enContra),
              Turnos.saldo(r.saldo)],
        ],
      });
      for (final pu in ed.value) {
        final pares = [
          for (final b in pu.balances)
            b.aMano
                ? '${b.a} y ${b.b}: estan a mano.'
                : 'Beneficiario: ${b.beneficiario} con ${_hm(b.horas)} (le debe a ${b.acreedor}).'
        ];
        bloques.add({
          'titulo': '${ed.key} - ${pu.nombre}',
          if (pares.isNotEmpty) 'texto': pares.join('\n'),
          'headers': ['Guardia', 'Dia', 'Ingreso', 'Salida', 'Turno', 'Horas', 'Saldo', 'Origen'],
          'rows': [for (final t in pu.turnos) _filaTurno(t, conGuardia: true)],
        });
      }
    }
    await _informe(
      titulo: 'Panel de horas · $periodo',
      archivo: 'Panel_Horas',
      textoCompartir: 'Panel de horas OSIRIS - $periodo',
      bloques: bloques,
    );
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
          if (_logoBytes != null)
            pw.Container(
              width: 60, height: 60,
              padding: const pw.EdgeInsets.all(6),
              decoration: pw.BoxDecoration(color: PdfColors.white, borderRadius: pw.BorderRadius.circular(10)),
              child: pw.Image(pw.MemoryImage(_logoBytes!), fit: pw.BoxFit.contain),
            )
          else
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

  /// Quita caracteres que la fuente PDF (Helvetica/Latin-1) no puede dibujar
  /// (emojis, guiones largos, viñetas), que si no HACEN FALLAR la generación.
  static String _safe(String s) {
    final b = StringBuffer();
    for (final r in s.runes) {
      if (r == 0x2022 || r == 0x00B7 || r == 0x2013 || r == 0x2014) {
        b.write('-');
      } else if (r == 0x2018 || r == 0x2019) {
        b.write("'");
      } else if (r == 0x201C || r == 0x201D) {
        b.write('"');
      } else if (r <= 0xFF) {
        b.writeCharCode(r);
      }
      // Cualquier otro (emoji, símbolos raros) se omite.
    }
    return b.toString();
  }

  /// Horas sin signo: "3 h 30 min" / "0 h".
  static String _hm(double horas) {
    final m = (horas * 60).round().abs();
    return m == 0 ? '0 h' : _safe(Turnos.duracion(Duration(minutes: m)));
  }

  static String _reglaHoras(int tolMin) =>
      'Turno normal 12 h (diurno 08:00-20:00, nocturno 20:00-08:00, o el horario de relevo del celular). '
      'En cada relevo: si el que entra llega tarde, esas horas son A FAVOR del que espero y EN CONTRA del '
      'que llego tarde; si el que sale se va antes, son EN CONTRA suyo y A FAVOR del que lo cubrio. '
      'Saldo = a favor - en contra. Tolerancia $tolMin min: hasta ese margen no cuenta; pasado el margen '
      'se cuentan todos los minutos. Beneficiario = el que hizo cubrir mas horas al otro en el mes.';

  static String _s(Object? v) {
    final s = _safe(v?.toString() ?? '');
    return s.length > 60 ? '${s.substring(0, 60)}...' : s;
  }

  static String _h(Object? iso) {
    try {
      // La nube guarda en UTC; se convierte a hora local para que coincida con
      // la hora real del celular.
      return DateFormat('dd/MM HH:mm').format(DateTime.parse(iso.toString()).toLocal());
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
