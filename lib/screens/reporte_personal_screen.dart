import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/app_state.dart';
import '../services/horas_local.dart';
import '../services/panel_horas.dart';
import '../services/turnos.dart';
import '../services/pdf_export.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Reporte de personal por mes: días trabajados, horas totales,
/// turnos de 24h (doble turno) y horas extra (más de 12h por turno).
class ReportePersonalScreen extends StatefulWidget {
  const ReportePersonalScreen({super.key});
  @override
  State<ReportePersonalScreen> createState() => _ReportePersonalScreenState();
}

class _ReportePersonalScreenState extends State<ReportePersonalScreen> {
  DateTime _mes = DateTime(DateTime.now().year, DateTime.now().month);
  List<ResumenGuardia> _data = [];
  bool _loading = true;
  bool _soloEsteCelular = false; // sin señal: solo los turnos de este celular

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  void _cambiarMes(int delta) {
    setState(() => _mes = DateTime(_mes.year, _mes.month + delta));
    _cargar();
  }

  int _carga = 0;

  /// Mismo cálculo que la pantalla Guardias y los PDF (PanelHoras).
  Future<void> _cargar() async {
    final carga = ++_carga;
    final mes = _mes;
    setState(() => _loading = true);
    List<ResumenGuardia> list;
    bool local = false;
    try {
      final h = await HorasPanel.edificio(mes);
      local = h.local && !AppState.instance.soloLocal;
      list = PanelHoras.porGuardia(h.puestos).values.toList()
        ..sort((a, b) => b.horas.compareTo(a.horas));
    } catch (_) {
      list = [];
    }
    // Si se cambió de mes mientras cargaba, este resultado ya no vale.
    if (!mounted || carga != _carga) return;
    setState(() {
      _data = list;
      _soloEsteCelular = local;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reporte de personal'),
        actions: [
          IconButton(
            icon: const Icon(Icons.balance),
            tooltip: 'Panel de horas: ingresos, salidas, 24/36 h y beneficiario (PDF)',
            onPressed: () => conEspera(context, () => PdfExport.panelHorasLocal(mes: _mes)),
          ),
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'Resumen del mes (PDF)',
            onPressed: () => conEspera(context, () => PdfExport.reporteGuardias(mes: _mes)),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(onPressed: () => _cambiarMes(-1), icon: const Icon(Icons.chevron_left)),
                Text(DateFormat('MMMM yyyy', 'es').format(_mes).toUpperCase(),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                IconButton(onPressed: () => _cambiarMes(1), icon: const Icon(Icons.chevron_right)),
              ],
            ),
          ),
          if (_soloEsteCelular && !_loading)
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text('Sin conexión: solo los turnos de este celular.',
                  style: TextStyle(fontSize: 12, color: Color(0xFFEF6C00))),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _data.isEmpty
                    ? const Center(child: Text('Sin turnos registrados este mes'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _data.length,
                        itemBuilder: (_, i) {
                          final r = _data[i];
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    const CircleAvatar(
                                        backgroundColor: Color(0x1A0A335D),
                                        child: Icon(Icons.shield, color: AppColors.azulMarino)),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(r.guardia,
                                          maxLines: 1, overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                    ),
                                  ]),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _chip('Dias', '${r.dias}', AppColors.azulMarino),
                                      _chip('Horas', r.horas.toStringAsFixed(1), AppColors.verde),
                                      _chip('24 h', '${r.n24}', const Color(0xFF6A1B9A)),
                                      _chip('36 h', '${r.n36}', const Color(0xFF6A1B9A)),
                                      _chip('Saldo', Turnos.saldo(r.saldo),
                                          r.saldo > 0 ? AppColors.verde : (r.saldo < 0 ? AppColors.rojo : Colors.blueGrey)),
                                      if (r.incompletos > 0) _chip('Incompletos', '${r.incompletos}', Colors.teal),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: color)),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ],
      ),
    );
  }
}
