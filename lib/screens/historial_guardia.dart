import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/panel_horas.dart';
import '../services/turnos.dart';
import '../theme.dart';

/// Historial completo de un guardia en el periodo: cada turno con fecha,
/// ingreso y salida reales, tipo (12/24/36 h), las horas a favor / en contra
/// que generó y de qué registro salió cada una (auditoría).
class HistorialGuardiaScreen extends StatefulWidget {
  final ResumenGuardia resumen;
  final String edificio;
  final String periodo;
  final Map<String, String> puestos;
  final int toleranciaMin;
  final Future<bool> Function(RegistroTurno t)? onCorregir;
  /// Datos del guardia (edificio, torre, turno, fecha de ingreso...).
  final Widget? cabecera;
  const HistorialGuardiaScreen({
    super.key,
    required this.toleranciaMin,
    required this.resumen,
    required this.edificio,
    required this.periodo,
    required this.puestos,
    this.onCorregir,
    this.cabecera,
  });

  @override
  State<HistorialGuardiaScreen> createState() => _HistorialGuardiaState();
}

class _HistorialGuardiaState extends State<HistorialGuardiaScreen> {
  static final _dia = DateFormat('EEE dd/MM', 'es');
  static final _hm = DateFormat('HH:mm');
  static final _dhm = DateFormat('EEE dd/MM HH:mm', 'es');

  Color _color(double h) {
    final m = (h * 60).round();
    return m > 0 ? AppColors.verde : (m < 0 ? AppColors.rojo : Colors.blueGrey);
  }

  Widget _dato(String valor, String etiqueta, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(valor, maxLines: 1, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
          Text(etiqueta, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ]),
      );

  String _estado(RegistroTurno t) {
    switch (t.estado) {
      case 'abierto':
        return 'En turno';
      case 'sin salida':
        return 'Sin salida · no se calcula';
      case 'sin ingreso':
        return 'Sin ingreso · no se calcula';
      case 'anulado':
        return 'Anulado';
      case 'inconsistente':
        return 'Registro inconsistente · no se calcula';
      default:
        return '';
    }
  }

  Widget _turno(RegistroTurno t) {
    final estado = _estado(t);
    final puesto = widget.puestos[t.puesto];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                '${_dia.format(t.inicio)} · ${t.valido ? 'Turno ${t.nivel} h' : 'Registro'}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (t.valido && t.movimientos.isNotEmpty)
              Text(Turnos.saldo(t.saldo),
                  style: TextStyle(fontWeight: FontWeight.bold, color: _color(t.saldo))),
            if (widget.onCorregir != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_calendar_outlined, size: 20),
                tooltip: 'Corregir',
                onPressed: () async {
                  final ok = await widget.onCorregir!(t);
                  if (ok && mounted) Navigator.pop(context); // el panel se recalculó
                },
              ),
          ]),
          Text(
            'Ingreso ${_dhm.format(t.inicio)}\n'
            'Salida ${t.fin == null ? '—' : _dhm.format(t.fin!)}'
            '${t.cerrado ? ' · ${Turnos.duracion(t.fin!.difference(t.inicio))}' : ''}',
            style: const TextStyle(fontSize: 13),
          ),
          if (t.progInicio != null)
            Text(
              'Programado ${_hm.format(t.progInicio!)} → ${_dhm.format(t.progFin!)}'
              '${puesto != null ? ' · $puesto' : ''}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          if (estado.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(estado,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: t.estado == 'abierto' ? AppColors.verde : const Color(0xFFEF6C00))),
            ),
          for (final m in t.movimientos)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${Turnos.saldo(m.horas)} · ${m.motivo}'
                '${m.con != null ? ' (${m.con})' : ''} · relevo ${_hm.format(m.programado)}, '
                'real ${_hm.format(m.real)}',
                style: TextStyle(fontSize: 12.5, color: _color(m.horas), fontWeight: FontWeight.w600),
              ),
            ),
          // Auditoría: de qué registros salió este turno.
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              [
                if (t.refIngreso != null) 'Ingreso: ${t.refIngreso}',
                if (t.refSalida != null) 'Salida: ${t.refSalida}',
                ...t.notas,
              ].join('\n'),
              style: const TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.resumen;
    final turnos = r.turnos.toList()..sort((a, b) => b.inicio.compareTo(a.inicio));
    final saldo = r.saldo;
    final m = (saldo * 60).round();
    return Scaffold(
      appBar: AppBar(title: Text(r.guardia, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('${widget.edificio} · ${widget.periodo}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 6),
                Text(Turnos.saldo(saldo),
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: _color(saldo))),
                Text(m > 0 ? 'Horas a favor' : (m < 0 ? 'Horas en contra' : 'Equilibrado'),
                    style: TextStyle(color: _color(saldo), fontWeight: FontWeight.w600)),
                Text('Tolerancia ${widget.toleranciaMin} min: pasado ese margen cuentan todos los minutos',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _dato(Turnos.saldo(r.aFavor).replaceFirst('+', ''), 'A favor', AppColors.verde),
                  _dato(Turnos.saldo(r.enContra).replaceFirst('+', ''), 'En contra', AppColors.rojo),
                  _dato('${r.dias}', 'Días', AppColors.azulMarino),
                  _dato('${r.n12}', '12 h', const Color(0xFF1565C0)),
                  _dato('${r.n24}', '24 h', AppColors.verde),
                  _dato('${r.n36}', '36 h', const Color(0xFF6A1B9A)),
                  _dato('${r.vecesTarde}', 'Tarde', AppColors.rojo),
                ]),
              ]),
            ),
          ),
          if (widget.cabecera != null) widget.cabecera!,
          if (turnos.isEmpty)
            const Card(child: ListTile(title: Text('Sin turnos en este periodo'))),
          for (final t in turnos) _turno(t),
        ],
      ),
    );
  }
}
