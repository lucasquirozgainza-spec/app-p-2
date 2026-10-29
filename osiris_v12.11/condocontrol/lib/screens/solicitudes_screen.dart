import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/app_state.dart';
import '../services/cloud.dart';
import '../services/guardias_service.dart';
import '../services/turnos.dart';
import '../services/solicitudes.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/toast.dart';

/// Pedir adelanto o día libre, y ver cómo va cada pedido. Pide el guardia
/// que está de turno en el celular (la pantalla se abre solo con turno iniciado).
class SolicitudesScreen extends StatefulWidget {
  const SolicitudesScreen({super.key});
  @override
  State<SolicitudesScreen> createState() => _SolicitudesScreenState();
}

class _SolicitudesScreenState extends State<SolicitudesScreen> {
  List<Solicitud>? _lista;
  String? _error;
  bool _enviando = false;
  Quien? _quien;

  @override
  void initState() {
    super.initState();
    final s = AppState.instance;
    // Pide SOLO el guardia de turno en este celular: así cada pedido queda en
    // su historial (en el monitor, por su CI).
    if (s.turnoActivoId != null && (s.userNombre ?? '').isNotEmpty) {
      _quien = Quien(s.userNombre!, (s.guardCi ?? '').trim());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cargar();
    });
  }

  Future<void> _cargar() async {
    final q = _quien;
    setState(() => _error = null);
    if (q == null) {
      setState(() => _lista = const []);
      return;
    }
    try {
      await Cloud.vaciarCola();
      final l = await Solicitudes.delGuardia(q);
      if (mounted && q == _quien) setState(() => _lista = l);
    } catch (_) {
      if (mounted) setState(() => _error = 'No hay conexión. Lo que pidas se envía cuando vuelva la señal.');
    }
  }

  Future<void> _hecho(String msg) async {
    if (!mounted) return;
    TopToast.show(context, msg);
    await Future.delayed(const Duration(milliseconds: 800));
    await _cargar();
  }

  // Reglas: el adelanto se pide con 24 h de anticipación y el día libre con
  // 48 h (antes de que empiece el turno de ese día). La lista de días solo
  // ofrece los que cumplen la regla, y el mensaje lo explica.
  static const _hAdelanto = 24, _hLibre = 48;

  /// Hora en que empieza el turno del guardia ese día (diurno: 1er relevo;
  /// nocturno: 2do relevo; franquero o sin dato: 00:00).
  Future<DateTime> Function(DateTime) _inicioDeTurno() {
    final s = AppState.instance;
    final h = [...s.horarios]..sort();
    String? turno;
    return (DateTime d) async {
      if (turno == null) {
        try {
          final gs = await GuardiasService.delEdificio(s.edificioId);
          final ci = GuardiasService.limpiarCi(s.guardCi ?? '');
          turno = gs.where((g) => GuardiasService.limpiarCi(g.ci) == ci).map((g) => g.turno).firstOrNull ?? '';
        } catch (_) {
          turno = '';
        }
      }
      final hh = turno == 'NOCTURNO' && h.length > 1 ? h[1] : (turno == 'DIURNO' && h.isNotEmpty ? h[0] : '00:00');
      final p = Turnos.parseHora(hh) ?? [0, 0];
      return DateTime(d.year, d.month, d.day, p[0], p[1]);
    };
  }

  Widget _diaDropdown(List<DateTime> dias, DateTime valor, void Function(DateTime) cambio, String etiqueta) {
    final hoy = DateTime.now();
    final manana = DateTime(hoy.year, hoy.month, hoy.day + 1);
    return DropdownButtonFormField<DateTime>(
      value: valor,
      isExpanded: true,
      menuMaxHeight: 360,
      decoration: InputDecoration(labelText: etiqueta, border: const OutlineInputBorder()),
      items: [
        for (final d in dias)
          DropdownMenuItem(
            value: d,
            child: Text((d == manana ? 'Mañana · ' : '') + DateFormat("EEEE dd 'de' MMMM", 'es').format(d)),
          ),
      ],
      onChanged: (v) {
        if (v != null) cambio(v);
      },
    );
  }

  Widget _regla(String texto) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFFFFF3E0), borderRadius: BorderRadius.circular(10)),
        child: Text(texto, style: const TextStyle(color: Color(0xFF8D4B00), fontWeight: FontWeight.w600)),
      );

  Future<void> _pedirAdelanto() async {
    final ahora = DateTime.now();
    final desde = ahora.add(const Duration(hours: _hAdelanto));
    final dias = [for (int i = 0; i < 45; i++) DateTime(desde.year, desde.month, desde.day + i)];
    DateTime dia = dias.first;
    final motivo = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Pedir adelanto'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              _regla('El adelanto se pide con $_hAdelanto horas de anticipación. '
                  'Lo puedes recibir desde ${DateFormat("EEEE dd 'a las' HH:mm", 'es').format(desde)}.'),
              const SizedBox(height: 12),
              _diaDropdown(dias, dia, (v) => set(() => dia = v), '¿Para qué día lo necesitas?'),
              const SizedBox(height: 12),
              TextField(
                controller: motivo,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Motivo (opcional)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              const Text('Si supervisión lo aprueba te llega un aviso. Cuando recibas el dinero, escribe aquí el monto.',
                  style: TextStyle(color: Colors.black54)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enviar')),
          ],
        ),
      ),
    );
    if (ok != true || _enviando) return;
    _enviando = true;
    try {
      await Solicitudes.pedirAdelanto(_quien!, motivo.text.trim(), dia);
      await _hecho('Pedido de adelanto enviado');
    } finally {
      _enviando = false;
    }
  }

  Future<void> _pedirLibre() async {
    final ahora = DateTime.now();
    final limite = ahora.add(const Duration(hours: _hLibre));
    final inicio = _inicioDeTurno();
    final dias = <DateTime>[];
    for (int i = 0; i < 100 && dias.length < 60; i++) {
      final d = DateTime(ahora.year, ahora.month, ahora.day + i);
      if (!(await inicio(d)).isBefore(limite)) dias.add(d);
    }
    if (!mounted || dias.isEmpty) return;
    DateTime dia = dias.first;
    final motivo = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Pedir día libre'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              _regla('El día libre se pide con $_hLibre horas de anticipación (antes de que empiece tu turno). '
                  'El primer día que puedes pedir es el ${DateFormat("EEEE dd 'de' MMMM", 'es').format(dias.first)}.'),
              const SizedBox(height: 12),
              _diaDropdown(dias, dia, (v) => set(() => dia = v), 'Día'),
              const SizedBox(height: 12),
              TextField(
                controller: motivo,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Motivo (opcional)', border: OutlineInputBorder()),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enviar')),
          ],
        ),
      ),
    );
    if (ok != true || _enviando) return;
    _enviando = true;
    try {
      await Solicitudes.pedirLibre(_quien!, dia, motivo.text.trim());
      await _hecho('Pedido de día libre enviado');
    } finally {
      _enviando = false;
    }
  }

  Future<void> _escribirMonto(Solicitud x) async {
    final c = TextEditingController();
    String? err;
    final monto = await showDialog<double>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Monto recibido'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Escribe cuánto te dieron de adelanto. Supervisión lo confirma.',
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: 'Monto', prefixText: 'Bs ', errorText: err, border: const OutlineInputBorder()),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () {
                final v = double.tryParse(c.text.trim().replaceAll(',', '.'));
                if (v == null || v <= 0 || v > 100000) {
                  set(() => err = 'Escribe un monto válido');
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: const Text('Enviar'),
            ),
          ],
        ),
      ),
    );
    if (monto == null || _enviando) return;
    _enviando = true;
    try {
      await Solicitudes.enviarMonto(_quien!, x, monto);
      await _hecho('Monto enviado: Bs ${Solicitudes.bs(monto)}');
    } finally {
      _enviando = false;
    }
  }

  Color _color(Solicitud x) {
    switch (x.estado) {
      case 'aprobado':
        return const Color(0xFF1565C0);
      case 'confirmado':
        return AppColors.verde;
      case 'rechazado':
      case 'no_entregado':
        return AppColors.rojo;
      case 'por_confirmar':
        return const Color(0xFFEF6C00);
      default:
        return const Color(0xFF607D8B);
    }
  }

  Widget _tile(Solicitud x) {
    final pedido = DateFormat('dd/MM HH:mm').format(x.cuando);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(x.titulo, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            Text(pedido, style: const TextStyle(color: Colors.black54, fontSize: 12)),
          ]),
          if (x.motivo.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(x.motivo, style: const TextStyle(color: Colors.black87)),
          ],
          const SizedBox(height: 8),
          Text(x.estadoTxt, style: TextStyle(color: _color(x), fontWeight: FontWeight.w600)),
          if (x.nota.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Supervisión: ${x.nota}', style: const TextStyle(color: Colors.black54)),
          ],
          if (x.esAdelanto && x.estado == 'aprobado') ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => _escribirMonto(x),
                child: const Text('Escribir monto recibido'),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final l = _lista;
    return Scaffold(
      appBar: AppBar(title: const Text('Solicitudes')),
      body: RefreshIndicator(
        onRefresh: _cargar,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.person, color: AppColors.azulMarino),
                title: Text(_quien?.nombre ?? 'Sin turno iniciado',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                subtitle: Text(s.edificioNombre),
              ),
            ),
            if (_quien == null)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text('Inicia tu turno para pedir.', style: TextStyle(color: AppColors.rojo)),
              ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton(onPressed: _quien == null ? null : _pedirAdelanto, child: const Text('Pedir adelanto')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF00695C)),
                    onPressed: _quien == null ? null : _pedirLibre,
                    child: const Text('Pedir día libre'),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 20),
            const Text('Mis pedidos', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.azulMarino)),
            const SizedBox(height: 8),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(_error!, style: const TextStyle(color: AppColors.rojo)),
              ),
            if (l == null && _error == null)
              const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
            else if (l != null && l.isEmpty)
              const Vacio('Todavía no pediste nada.')
            else if (l != null)
              ...l.map(_tile),
          ],
        ),
      ),
    );
  }
}
