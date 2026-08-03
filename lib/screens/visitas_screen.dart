import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../db/database_helper.dart';
import '../services/app_state.dart';
import '../services/audit.dart';
import '../services/cloud.dart';
import '../services/contact_launch.dart';
import '../services/contactos_repo.dart';
import '../services/ocr_service.dart';
import 'camera_screen.dart';
import '../services/device_context.dart';
import '../theme.dart';
import '../widgets/photo_field.dart';
import '../widgets/common.dart';
import '../widgets/toast.dart';
import '../widgets/eventos_remotos.dart';

class VisitasScreen extends StatefulWidget {
  const VisitasScreen({super.key});
  @override
  State<VisitasScreen> createState() => _VisitasScreenState();
}

class _VisitasScreenState extends State<VisitasScreen> {
  List<Map<String, dynamic>> _visitas = [];
  bool _soloDentro = true;
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final q = _q.text.trim();
    final where = StringBuffer('edificio=?');
    final args = <dynamic>[ed];
    if (_soloDentro) {
      where.write(" AND estado='dentro'");
    }
    if (q.isNotEmpty) {
      where.write(' AND (nombre_visita LIKE ? OR ci LIKE ? OR depto LIKE ? OR placa LIKE ? OR tarjeta_num LIKE ? OR autoriza LIKE ?)');
      final like = '%$q%';
      args.addAll([like, like, like, like, like, like]);
    }
    final rows = await db.query('visitas', where: where.toString(), whereArgs: args, orderBy: 'id DESC');
    if (!mounted) return;
    setState(() => _visitas = rows);
  }

  Future<void> _registrarSalida(Map<String, dynamic> v) async {
    final tieneTarjeta = (v['tarjeta']?.toString() ?? '').isNotEmpty;
    bool devuelta = true;
    if (tieneTarjeta) {
      final r = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.badge, color: AppColors.azulMarino, size: 36),
          title: const Text('Devolucion de tarjeta'),
          content: Text('¿La visita de ${v['nombre_visita'] ?? ''} (depto ${v['depto'] ?? ''}) devolvio la tarjeta de acceso?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('NO devolvio', style: TextStyle(color: AppColors.rojo))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Si, devolvio')),
          ],
        ),
      );
      if (r == null) return;
      devuelta = r;
    }
    final db = await DB.instance.database;
    await db.update('visitas', {
      'estado': 'salio',
      'hora_salida': DateTime.now().toIso8601String(),
      'tarjeta_devuelta': devuelta ? 1 : 0,
    }, where: 'id=?', whereArgs: [v['id']]);
    if (tieneTarjeta && !devuelta) {
      final guardiaActual = AppState.instance.userNombre ?? 'Sin turno';
      final guardiaAsigno = v['guardia_nombre']?.toString() ?? 'desconocido';
      await db.insert('advertencias', {
        'guardia_nombre': guardiaActual,
        'mensaje': 'Tarjeta NO devuelta - visita ${v['nombre_visita'] ?? ''} (depto ${v['depto'] ?? ''}). '
            'Tarjeta N° ${v['tarjeta_num'] ?? '-'}. La asigno: $guardiaAsigno. Registro la salida: $guardiaActual.',
        'tipo': 'tarjeta',
        'edificio': AppState.instance.edificioId,
        'created_at': DateTime.now().toIso8601String(),
      });
    }
    await Audit.log('SALIDA_VISITA', 'visitas', '${v['id']}');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Visitas'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: SegmentedButton<bool>(
              style: SegmentedButton.styleFrom(
                  backgroundColor: Colors.white, selectedBackgroundColor: Colors.white),
              segments: const [
                ButtonSegment(value: true, label: Text('Dentro'), icon: Icon(Icons.login)),
                ButtonSegment(value: false, label: Text('Todas'), icon: Icon(Icons.list)),
              ],
              selected: {_soloDentro},
              onSelectionChanged: (s) {
                setState(() => _soloDentro = s.first);
                _load();
              },
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.azulMarino,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Nueva visita'),
        onPressed: () async {
          await Navigator.push(context,
              MaterialPageRoute(builder: (_) => const VisitaFormScreen()));
          _load();
        },
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _q,
              onChanged: (_) => _load(),
              decoration: const InputDecoration(
                hintText: 'Buscar nombre, CI, depto, placa, N° tarjeta...',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _visitas.length + 1,
              itemBuilder: (_, i) {
                if (i == _visitas.length) {
                  return Column(children: const [
                    EventosRemotos(tipo: 'Visita', icon: Icons.badge, color: Color(0xFF00897B),
                        tituloKeys: ['nombre', 'depto']),
                  ]);
                }
                final v = _visitas[i];
                final dentro = v['estado'] == 'dentro';
                final hora = DateFormat('dd/MM HH:mm')
                    .format(DateTime.parse(v['created_at'] as String));
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: dentro
                          ? AppColors.verde.withOpacity(.15)
                          : Colors.grey.shade200,
                      backgroundImage: (v['foto_visitante'] != null &&
                              File(v['foto_visitante'] as String).existsSync())
                          ? FileImage(File(v['foto_visitante'] as String))
                          : null,
                      child: (v['foto_visitante'] == null)
                          ? Icon(Icons.person,
                              color: dentro ? AppColors.verde : Colors.grey)
                          : null,
                    ),
                    title: Text(v['nombre_visita']?.toString() ?? '—',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        'Depto ${v['depto'] ?? '-'} · ${v['motivo'] ?? ''}\nIngreso: $hora'),
                    isThreeLine: true,
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => VisitaDetalle(visita: v))),
                    trailing: dentro
                        ? TextButton(
                            onPressed: () => _registrarSalida(v),
                            child: const Text('Salida',
                                style: TextStyle(color: AppColors.rojo)))
                        : const Icon(Icons.check_circle, color: Colors.grey),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class VisitaDetalle extends StatelessWidget {
  final Map<String, dynamic> visita;
  const VisitaDetalle({super.key, required this.visita});

  Widget _foto(BuildContext context, String label, Object? path) {
    final p = path?.toString() ?? '';
    if (p.isEmpty || !File(p).existsSync()) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
          TextButton.icon(
            onPressed: () => Share.shareXFiles([XFile(p)], text: 'Foto $label'),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Guardar/Compartir'),
          ),
        ]),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: () => showDialog(context: context, builder: (_) => Dialog(
              child: InteractiveViewer(child: Image.file(File(p))))),
          child: ClipRRect(borderRadius: BorderRadius.circular(10),
              child: Image.file(File(p), height: 200, width: double.infinity, fit: BoxFit.cover,
                  gaplessPlayback: true, cacheWidth: 1000,
                  errorBuilder: (_, __, ___) => Container(height: 200, color: Colors.black12,
                      child: const Center(child: Icon(Icons.broken_image, color: Colors.grey, size: 40))))),
        ),
      ]),
    );
  }

  Widget _dato(String label, Object? value) {
    final v = value?.toString() ?? '';
    if (v.isEmpty) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      title: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      subtitle: Text(v, style: const TextStyle(fontSize: 15, color: Colors.black87)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = visita;
    final creado = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(v['created_at'] as String));
    final devuelta = v['tarjeta_devuelta'] == 1;
    final tieneTarjeta = (v['tarjeta']?.toString() ?? '').isNotEmpty || (v['tarjeta_num']?.toString() ?? '').isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(v['nombre_visita']?.toString() ?? 'Visita')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(child: Column(children: [
            _dato('Nombre', v['nombre_visita']),
            _dato('CI', v['ci']),
            _dato('Departamento', v['depto']),
            _dato('Autoriza', v['autoriza']),
            _dato('Motivo', v['motivo']),
            _dato('Placa', v['placa']),
            _dato('N° de tarjeta', v['tarjeta_num']),
            _dato('Guardia', v['guardia_nombre']),
            _dato('Ingreso', creado),
            _dato('Estado', v['estado'] == 'dentro' ? 'Dentro del edificio' : 'Salio'),
            if (tieneTarjeta)
              _dato('Tarjeta', devuelta ? 'Devuelta' : (v['estado'] == 'salio' ? 'NO devuelta' : 'En poder de la visita')),
            _dato('Observaciones', v['observaciones']),
          ])),
          const SizedBox(height: 12),
          _foto(context, 'Tarjeta asignada', v['tarjeta']),
          _foto(context, 'Carnet anverso', v['foto_ci']),
          _foto(context, 'Carnet reverso', v['foto_visitante']),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class VisitaFormScreen extends StatefulWidget {
  const VisitaFormScreen({super.key});
  @override
  State<VisitaFormScreen> createState() => _VisitaFormScreenState();
}

class _VisitaFormScreenState extends State<VisitaFormScreen> {
  final _nombre = TextEditingController();
  final _depto = TextEditingController();
  final _autoriza = TextEditingController();
  final _ci = TextEditingController();
  final _motivo = TextEditingController();
  final _cantidad = TextEditingController(text: '1');
  final _placa = TextEditingController();
  final _obs = TextEditingController();
  final _tarjetaNum = TextEditingController();
  String? _fotoTarjeta;
  String? _motivoSel; // motivo elegido por boton (o 'Otro' = manual)
  bool _ocrLeyendo = false;
  List<String> _deptoSug = [];
  String? _carnetAnverso;
  String? _carnetReverso;
  String _carnetTexto = '';
  bool _tieneVehiculo = false;
  bool _saving = false;
  final _ahora = DateTime.now();

  void _snack(String m) => TopToast.show(context, m, color: AppColors.rojo, icon: Icons.error_outline);

  /// Captura la tarjeta (cámara propia, sin confirmar) y lee el número en
  /// SEGUNDO PLANO para no demorar. Si no lo lee, avisa para repetir manual.
  Future<void> _capturarTarjeta() async {
    final res = await Navigator.push<List<String>>(
        context, MaterialPageRoute(builder: (_) => const CameraScreen(multi: false, album: 'OSIRIS Tarjetas')));
    if (res == null || res.isEmpty) return;
    final path = res.first;
    final dig = AppState.instance.tarjetaDigitos;
    setState(() => _fotoTarjeta = path);
    // OCR en segundo plano.
    () async {
      final num = await OcrService.leerNumero(path, digitos: dig);
      if (!mounted) return;
      if (num != null && num.length == dig) {
        setState(() => _tarjetaNum.text = num);
        TopToast.show(context, 'N° de tarjeta: $num');
      } else {
        TopToast.show(context, 'No se leyó la tarjeta, escríbela o repite la foto',
            color: AppColors.rojo, icon: Icons.error_outline);
      }
    }();
  }

  /// Captura los DOS lados del carnet en UNA sola sesión (sin reabrir) y lee
  /// CI+nombre en SEGUNDO PLANO para no demorar el registro.
  Future<void> _capturarCarnet() async {
    final res = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(builder: (_) => const CameraScreen(multi: true, minFotos: 2, album: 'OSIRIS Carnet')),
    );
    if (res == null || res.isEmpty) return;
    setState(() {
      _carnetAnverso = res.isNotEmpty ? res[0] : null;
      _carnetReverso = res.length > 1 ? res[1] : null;
    });
    // OCR en segundo plano: no bloquea el formulario.
    () async {
      String texto = '';
      for (final path in res) {
        texto = '$texto\n${await OcrService.leerTexto(path)}';
      }
      final data = OcrService.parseCarnet(texto);
      if (!mounted) return;
      _carnetTexto = texto;
      setState(() {
        if (data.ci != null) _ci.text = data.ci!;
        if (data.nombre != null) _nombre.text = data.nombre!;
      });
      if (data.ci != null || data.nombre != null) {
        TopToast.show(context, 'Detectado: ${data.nombre ?? ''} ${data.ci ?? ''}'.trim());
      }
    }();
  }

  /// Lee el carnet (anverso o reverso), acumula el texto y llena CI y nombre.
  Future<void> _procesarCarnet(String? path, bool anverso) async {
    if (anverso) {
      _carnetAnverso = path;
    } else {
      _carnetReverso = path;
    }
    if (path == null) return;
    setState(() => _ocrLeyendo = true);
    final t = await OcrService.leerTexto(path);
    _carnetTexto = '$_carnetTexto\n$t';
    final data = OcrService.parseCarnet(_carnetTexto);
    if (!mounted) return;
    setState(() {
      _ocrLeyendo = false;
      // Se rellena con lo detectado (el guardia puede corregir despues).
      if (data.ci != null) _ci.text = data.ci!;
      if (data.nombre != null) _nombre.text = data.nombre!;
    });
    if (data.ci != null || data.nombre != null) {
      TopToast.show(context, 'Detectado: ${data.nombre ?? ''} ${data.ci ?? ''}'.trim());
    }
  }

  Future<void> _sugerirDeptos() async {
    final t = _depto.text.trim();
    if (t.isEmpty) {
      setState(() => _deptoSug = []);
      return;
    }
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final rows = await db.rawQuery(
        'SELECT DISTINCT depto FROM propietarios WHERE edificio=? AND depto LIKE ? ORDER BY depto LIMIT 8',
        [ed, '$t%']);
    final sug = rows.map((r) => r['depto'].toString()).where((d) => d.isNotEmpty && d != t).toList();
    if (!mounted) return;
    setState(() => _deptoSug = sug);
  }

  Future<List<Map<String, dynamic>>> _consultarContactos(String depto) async {
    final db = await DB.instance.database;
    final ed = AppState.instance.edificioId;
    final out = <Map<String, dynamic>>[];
    final props = await db.query('propietarios', where: 'edificio=? AND depto=?', whereArgs: [ed, depto]);
    for (final p in props) {
      if ((p['copropietario']?.toString() ?? '').isNotEmpty) {
        out.add({'nombre': p['copropietario'], 'tel': p['telefono'], 'rol': 'Propietario'});
      }
      if ((p['inquilino']?.toString() ?? '').isNotEmpty) {
        out.add({'nombre': p['inquilino'], 'tel': p['telefono_inq'], 'rol': 'Inquilino'});
      }
    }
    final resis = await db.query('residentes', where: 'edificio=? AND depto=?', whereArgs: [ed, depto]);
    for (final r in resis) {
      out.add({'nombre': r['nombre'], 'tel': r['celular'], 'rol': 'Residente'});
    }
    return out;
  }

  // Anuncia la visita a esa persona por WhatsApp y la deja como quien autoriza.
  void _anunciar(String nombre, String tel, String depto) {
    setState(() => _autoriza.text = nombre);
    Navigator.pop(context);
    Contacto.whatsapp(context, tel,
        mensaje: 'Tiene una visita: ${_nombre.text}. ¿Autoriza el ingreso al depto $depto?');
  }

  void _elegir(String nombre) {
    setState(() => _autoriza.text = nombre);
    Navigator.pop(context);
  }

  Future<void> _mostrarContactos() async {
    final depto = _depto.text.trim();
    if (depto.isEmpty) return _snack('Primero escribe el departamento');
    final contactos = await _consultarContactos(depto);
    final enc = await ContactosRepo.encargado(depto);
    if (!mounted) return;

    // Predeterminado: el encargado si existe; si no, el primero con telefono.
    Map<String, dynamic>? pred;
    if (enc != null && enc.tel.trim().isNotEmpty) {
      pred = {'nombre': enc.nombre, 'tel': enc.tel, 'rol': 'Encargado'};
    } else {
      pred = contactos.firstWhere((c) => (c['tel']?.toString() ?? '').trim().isNotEmpty,
          orElse: () => <String, dynamic>{});
      if (pred.isEmpty) pred = null;
    }
    final otros = contactos.where((c) =>
        !(pred != null && c['nombre'] == pred['nombre'] && c['tel'] == pred['tel'])).toList();

    // Fila compacta para cada residente: nombre + iconos pequeños (contactar /
    // autorizó). Sin doble fila, directo y minimalista.
    Widget filaResidente(Map<String, dynamic> c) {
      final tel = (c['tel']?.toString() ?? '').trim();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(
            child: Text('${c['nombre']}  ·  ${c['rol']}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
          ),
          if (tel.isNotEmpty)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.sms, color: AppColors.verde, size: 22),
              tooltip: 'Anunciar visita',
              onPressed: () => _anunciar(c['nombre'].toString(), tel, depto),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.check_circle, color: Color(0xFF1565C0), size: 24),
            tooltip: 'Autorizó',
            onPressed: () => _elegir(c['nombre'].toString()),
          ),
        ]),
      );
    }

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        title: Text('Depto $depto'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              if (pred != null) ...[
                Text('${pred['nombre']}  ·  ${pred['rol']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.verde, minimumSize: const Size.fromHeight(46)),
                    onPressed: () => _anunciar(pred!['nombre'].toString(), pred!['tel'].toString(), depto),
                    icon: const Icon(Icons.sms, size: 18),
                    label: const Text('Anunciar', maxLines: 1),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () { Navigator.pop(context); Contacto.llamar(context, pred!['tel'].toString()); },
                    icon: const Icon(Icons.call, size: 18),
                    label: const Text('Llamar', maxLines: 1),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1565C0), minimumSize: const Size.fromHeight(46)),
                    onPressed: () => _elegir(pred!['nombre'].toString()),
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Autorizó', maxLines: 1),
                  ),
                ),
              ],
              if (otros.isNotEmpty) ...[
                const Divider(height: 18),
                for (final c in otros) filaResidente(c),
              ],
              if (pred == null && otros.isEmpty)
                const Padding(padding: EdgeInsets.all(8), child: Text('No hay personas registradas para ese departamento.')),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
      ),
    );
  }

  Future<void> _guardar() async {
    final pideCarnet = AppState.instance.campoVisita('v_carnet');
    final pideTarjeta = AppState.instance.campoVisita('v_tarjeta');
    if (_nombre.text.trim().isEmpty) return _snack('Ingrese el nombre del visitante');
    final dig = AppState.instance.tarjetaDigitos;
    if (pideTarjeta && _fotoTarjeta != null && _tarjetaNum.text.trim().length != dig) {
      return _snack('La tarjeta debe tener $dig dígitos. Repite la foto de la tarjeta.');
    }
    if (pideCarnet && _carnetAnverso == null) return _snack('La foto del carnet (anverso) es obligatoria');
    if (pideCarnet && _carnetReverso == null) return _snack('La foto del carnet (reverso) es obligatoria');
    setState(() => _saving = true);
    final s = AppState.instance;
    final db = await DB.instance.database;
    // Guardado LOCAL inmediato (sin esperar GPS ni nube) para poder registrar
    // al siguiente al instante. La ubicación y la nube se completan solas.
    final id = await db.insert('visitas', {
      'guardia_id': s.userId,
      'guardia_nombre': s.userNombre,
      'tarjeta': _fotoTarjeta,
      'tarjeta_num': _tarjetaNum.text.trim(),
      'nombre_visita': _nombre.text.trim(),
      'ci': _ci.text,
      'foto_ci': _carnetAnverso,
      'foto_visitante': _carnetReverso,
      'depto': _depto.text,
      'autoriza': _autoriza.text,
      'motivo': _motivo.text,
      'cantidad': int.tryParse(_cantidad.text) ?? 1,
      'placa': _tieneVehiculo ? _placa.text.trim() : '',
      'observaciones': _obs.text,
      'estado': 'dentro',
      'edificio': s.edificioId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await Audit.log('CREAR', 'visitas', '$id', detalle: _nombre.text);
    // Todo lo lento (GPS, dispositivo, subir foto, evento) en SEGUNDO PLANO.
    final fotoNube = _carnetAnverso ?? _fotoTarjeta ?? _carnetReverso;
    final det = {
      'nombre': _nombre.text.trim(),
      'ci': _ci.text.trim(),
      'depto': _depto.text.trim(),
      'autoriza': _autoriza.text.trim(),
      'placa': _tieneVehiculo ? _placa.text.trim() : '',
      'tarjeta': _tarjetaNum.text.trim(),
      'motivo': _motivo.text.trim(),
    };
    () async {
      try {
        final gps = await DeviceContext.gps();
        final disp = await DeviceContext.dispositivo();
        await db.update('visitas',
            {'gps_lat': gps?['lat'], 'gps_lng': gps?['lng'], 'dispositivo': disp},
            where: 'id=?', whereArgs: [id]);
      } catch (_) {}
      final fotoUrl = fotoNube != null ? await Cloud.subirFoto(fotoNube) : null;
      await Cloud.evento('Visita', detalle: {...det, if (fotoUrl != null) 'foto_url': fotoUrl});
    }();
    if (!mounted) return;
    Navigator.pop(context);
  }

  Widget _miniCarnet(String path, String label) {
    return Expanded(
      child: Column(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(File(path), height: 90, width: double.infinity, fit: BoxFit.cover,
              gaplessPlayback: true, cacheWidth: 600,
              errorBuilder: (_, __, ___) => Container(height: 90, color: Colors.black12,
                  child: const Icon(Icons.broken_image, color: Colors.grey))),
        ),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ]),
    );
  }

  Widget _paso(String n, String t, Color c) => Container(
        margin: const EdgeInsets.only(top: 14, bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: c.withOpacity(.10),
          borderRadius: BorderRadius.circular(12),
          border: Border(left: BorderSide(color: c, width: 4)),
        ),
        child: Row(children: [
          CircleAvatar(radius: 13, backgroundColor: c,
              child: Text(n, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))),
          const SizedBox(width: 10),
          Expanded(child: Text(t, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: c))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Registrar Visita')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        // PASO 1: Depto y autorizacion
        _paso('1', 'Departamento', AppColors.verde),
        TextField(controller: _depto,
            decoration: const InputDecoration(
              labelText: 'Depto (ej. 303)',
              prefixIcon: Icon(Icons.meeting_room),
            ),
            onChanged: (_) => _sugerirDeptos()),
        if (_deptoSug.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final d in _deptoSug)
                ActionChip(
                  label: Text(d),
                  backgroundColor: AppColors.grisClaro,
                  onPressed: () {
                    _depto.text = d;
                    setState(() => _deptoSug = []);
                    _mostrarContactos();
                  },
                ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _mostrarContactos,
            style: FilledButton.styleFrom(backgroundColor: AppColors.verde),
            icon: const Icon(Icons.phone_in_talk),
            label: const Text('Llamar para autorizar'),
          ),
        ),
        if (_autoriza.text.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          LockedField(label: 'Autoriza', value: _autoriza.text, icon: Icons.how_to_reg),
        ],
        const SizedBox(height: 8),
        // PASO 2: Tarjeta (configurable por edificio)
        if (s.campoVisita('v_tarjeta')) ...[
          _paso('2', 'Tarjeta', const Color(0xFFEF6C00)),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), backgroundColor: const Color(0xFFEF6C00)),
              onPressed: _capturarTarjeta,
              icon: const Icon(Icons.camera_alt),
              label: Text(_fotoTarjeta == null ? 'Foto de la tarjeta' : 'Repetir tarjeta'),
            ),
          ),
          const SizedBox(height: 8),
          if (_fotoTarjeta != null)
            Row(children: [_miniCarnet(_fotoTarjeta!, 'Tarjeta')]),
          TextField(controller: _tarjetaNum, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'N° de tarjeta')),
          const SizedBox(height: 12),
        ],
        // PASO 3: Carnet -> llena nombre y CI solos
        _paso(s.campoVisita('v_tarjeta') ? '3' : '2', 'Carnet', const Color(0xFF00838F)),
        if (s.campoVisita('v_carnet')) ...[
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), backgroundColor: const Color(0xFF00838F)),
              onPressed: _capturarCarnet,
              icon: const Icon(Icons.camera_alt),
              label: Text(_carnetAnverso == null ? 'Foto del carnet (2 lados)' : 'Repetir carnet'),
            ),
          ),
          const SizedBox(height: 8),
          if (_carnetAnverso != null || _carnetReverso != null)
            Row(children: [
              if (_carnetAnverso != null)
                _miniCarnet(_carnetAnverso!, 'Adelante'),
              if (_carnetReverso != null) ...[
                const SizedBox(width: 8),
                _miniCarnet(_carnetReverso!, 'Atrás'),
              ],
            ]),
          if (_ocrLeyendo)
            const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 8),
              child: Row(children: [
                SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2.5)),
                SizedBox(width: 8),
                Text('Leyendo el carnet...', style: TextStyle(color: AppColors.azulMarino)),
              ]),
            ),
          const SizedBox(height: 8),
        ],
        TextField(controller: _nombre, textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Nombre *', prefixIcon: Icon(Icons.person))),
        const SizedBox(height: 12),
        TextField(controller: _ci, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'CI / documento', prefixIcon: Icon(Icons.badge))),
        const SizedBox(height: 12),
        // PASO 4: Vehiculo, motivo, observaciones
        _paso('4', 'Detalles', const Color(0xFF6A1B9A)),
        if (s.campoVisita('v_vehiculo')) ...[
          SwitchListTile(
            value: _tieneVehiculo,
            onChanged: (v) => setState(() => _tieneVehiculo = v),
            title: const Text('¿Ingresa con vehiculo?'),
            activeColor: AppColors.verde,
            contentPadding: EdgeInsets.zero,
          ),
          if (_tieneVehiculo)
            TextField(controller: _placa, textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Placa del vehiculo', prefixIcon: Icon(Icons.directions_car))),
          const SizedBox(height: 12),
        ],
        if (s.campoVisita('v_motivo')) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('Motivo', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final m in const ['Técnico', 'Limpieza', 'Visita'])
              ChoiceChip(
                label: Text(m),
                selected: _motivoSel == m,
                selectedColor: AppColors.verde,
                labelStyle: TextStyle(
                    color: _motivoSel == m ? Colors.white : null,
                    fontWeight: FontWeight.w600),
                onSelected: (_) => setState(() {
                  _motivoSel = m;
                  _motivo.text = m;
                }),
              ),
            ChoiceChip(
              label: const Text('Otro'),
              selected: _motivoSel == 'Otro',
              selectedColor: const Color(0xFF6A1B9A),
              labelStyle: TextStyle(
                  color: _motivoSel == 'Otro' ? Colors.white : null,
                  fontWeight: FontWeight.w600),
              onSelected: (_) => setState(() {
                _motivoSel = 'Otro';
                _motivo.clear();
              }),
            ),
          ]),
          if (_motivoSel == 'Otro')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                  controller: _motivo,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Especifica el motivo')),
            ),
          const SizedBox(height: 12),
        ],
        TextField(controller: _obs, maxLines: 2, decoration: const InputDecoration(labelText: 'Observaciones')),
        const SizedBox(height: 12),
        LockedField(label: 'Guardia', value: s.userNombre ?? '', icon: Icons.shield),
        Row(children: [
          Expanded(child: LockedField(label: 'Fecha', value: DateFormat('dd/MM/yyyy').format(_ahora), icon: Icons.calendar_today)),
          const SizedBox(width: 10),
          Expanded(child: LockedField(label: 'Hora ingreso', value: DateFormat('HH:mm').format(_ahora), icon: Icons.access_time)),
        ]),
        const SizedBox(height: 8),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppColors.verde, minimumSize: const Size.fromHeight(52)),
          onPressed: _saving ? null : _guardar,
          icon: _saving
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
              : const Icon(Icons.save),
          label: const Text('Registrar ingreso'),
        ),
      ]),
    );
  }
}

