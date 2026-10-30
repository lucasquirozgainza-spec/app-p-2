import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../theme.dart';

/// Resultado de un pedido (adelanto o día libre).
class PedidoDatos {
  final DateTime dia;
  final double? monto; // solo adelanto
  final String motivo;
  const PedidoDatos(this.dia, this.monto, this.motivo);
}

/// Pantalla para pedir ADELANTO (monto + día) o DÍA LIBRE (día), con un
/// calendario de verdad: solo se pueden tocar los días permitidos
/// (adelanto: desde 24 h después del pedido; día libre: 48 h antes de que
/// empiece el turno de ese día). Los días bloqueados se ven apagados.
class PedidoScreen extends StatefulWidget {
  final bool adelanto;
  final Set<DateTime> diasPermitidos; // días (00:00) que se pueden elegir
  final String regla; // texto corto de la regla
  const PedidoScreen({super.key, required this.adelanto, required this.diasPermitidos, required this.regla});

  @override
  State<PedidoScreen> createState() => _PedidoScreenState();
}

class _PedidoScreenState extends State<PedidoScreen> {
  final _monto = TextEditingController();
  final _motivo = TextEditingController();
  DateTime? _dia;
  String? _errMonto, _errDia;

  static DateTime _d(DateTime x) => DateTime(x.year, x.month, x.day);
  bool _permitido(DateTime x) => widget.diasPermitidos.contains(_d(x));

  @override
  void initState() {
    super.initState();
    final l = widget.diasPermitidos.toList()..sort();
    _dia = l.isNotEmpty ? l.first : null;
  }

  @override
  void dispose() {
    _monto.dispose();
    _motivo.dispose();
    super.dispose();
  }

  void _enviar() {
    double? m;
    setState(() {
      _errMonto = null;
      _errDia = null;
    });
    if (widget.adelanto) {
      m = double.tryParse(_monto.text.trim().replaceAll(',', '.'));
      if (m == null || m <= 0 || m > 100000) {
        setState(() => _errMonto = 'Escribe cuánto necesitas');
        return;
      }
    }
    if (_dia == null || !_permitido(_dia!)) {
      setState(() => _errDia = 'Elige un día habilitado en el calendario');
      return;
    }
    Navigator.pop(context, PedidoDatos(_dia!, m, _motivo.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.diasPermitidos.toList()..sort();
    final primero = l.isNotEmpty ? l.first : _d(DateTime.now());
    final ultimo = l.isNotEmpty ? l.last : primero;
    final color = widget.adelanto ? AppColors.azulMarino : const Color(0xFF00695C);
    final fmt = DateFormat("EEEE d 'de' MMMM", 'es');
    return Scaffold(
      appBar: AppBar(title: Text(widget.adelanto ? 'Pedir adelanto' : 'Pedir día libre')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            // Regla, discreta
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.schedule, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.regla, style: const TextStyle(color: Colors.black54, fontSize: 13.5))),
            ]),
            const SizedBox(height: 16),
            if (widget.adelanto) ...[
              const Text('¿Cuánto necesitas?', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 8),
              TextField(
                controller: _monto,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                decoration: InputDecoration(
                  prefixText: 'Bs  ',
                  prefixStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Colors.black54),
                  hintText: '0',
                  errorText: _errMonto,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 20),
            ],
            Text(widget.adelanto ? '¿Para qué día lo necesitas?' : '¿Qué día quieres libre?',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: _errDia != null ? AppColors.rojo : Colors.black12),
              ),
              child: Theme(
                data: Theme.of(context).copyWith(colorScheme: Theme.of(context).colorScheme.copyWith(primary: color)),
                child: CalendarDatePicker(
                  initialDate: _dia ?? primero,
                  firstDate: _d(DateTime.now()),
                  lastDate: ultimo,
                  currentDate: _d(DateTime.now()),
                  selectableDayPredicate: _permitido,
                  onDateChanged: (v) => setState(() {
                    _dia = _d(v);
                    _errDia = null;
                  }),
                ),
              ),
            ),
            if (_errDia != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(_errDia!, style: const TextStyle(color: AppColors.rojo, fontSize: 12.5)),
              ),
            const SizedBox(height: 8),
            if (_dia != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(color: color.withOpacity(.07), borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Icon(Icons.event_available, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      fmt.format(_dia!).replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase()),
                      style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: 15),
                    ),
                  ),
                ]),
              ),
            const SizedBox(height: 18),
            TextField(
              controller: _motivo,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Motivo (opcional)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 54,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: color, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: _enviar,
                child: Text(widget.adelanto ? 'Enviar pedido de adelanto' : 'Enviar pedido de día libre',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.adelanto
                  ? 'Si supervisión lo aprueba te llega un aviso. Cuando recibas el dinero, escribe aquí lo que te dieron.'
                  : 'Si supervisión lo aprueba te llega un aviso.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black45, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}
