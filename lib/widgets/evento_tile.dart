import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/cloud.dart';
import '../theme.dart';

/// Ícono por tipo de registro.
IconData iconoEvento(String? tipo) {
  switch (tipo) {
    case 'Visita':
      return Icons.badge;
    case 'Ronda':
      return Icons.directions_walk;
    case 'Incidente':
      return Icons.warning_amber;
    case 'Ingreso de turno':
      return Icons.login;
    case 'Salida de turno':
      return Icons.logout;
    case 'Encomienda':
      return Icons.inventory_2;
    case 'Hospedaje':
      return Icons.hotel;
    case 'Guardia sin uniforme':
      return Icons.checkroom;
    case 'Doblar turno':
      return Icons.timelapse;
    case 'Advertencia':
      return Icons.report_problem_outlined;
    default:
      return Icons.event_note;
  }
}

Map _detalle(Map<String, dynamic> e) {
  try {
    final d = e['detalle'];
    final m = d is String ? jsonDecode(d) : d;
    if (m is Map) return m;
  } catch (_) {}
  return const {};
}

/// Datos internos que no se muestran (ids, horas técnicas, fotos, GPS).
const _ocultos = {
  'bloque', 'uid', 'ts', 'turno_ref', 'relevos', 'ubicacion', 'foto_url', 'fotos_url', 'nivel', 'guard_ci',
  'device', 'cargo',
};

/// Resumen corto del detalle de un registro.
String resumenEvento(Map<String, dynamic> e) {
  final m = _detalle(e);
  return m.entries
      .where((x) => !_ocultos.contains(x.key) && '${x.value}'.trim().isNotEmpty)
      .map((x) => '${x.value}')
      .join(' · ');
}

/// Fila de un registro: hora, tipo, guardia, bloque y resumen.
class EventoTile extends StatelessWidget {
  final Map<String, dynamic> e;
  const EventoTile(this.e, {super.key});

  @override
  Widget build(BuildContext context) {
    final bloque = '${_detalle(e)['bloque'] ?? ''}';
    final hora = Cloud.horaEvento(e);
    final sub = resumenEvento(e);
    return Card(
      child: ListTile(
        dense: true,
        onTap: () => mostrarEvento(context, e),
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.azulMarino.withOpacity(.1),
          child: Icon(iconoEvento(e['tipo']?.toString()), color: AppColors.azulMarino, size: 18),
        ),
        title: Text('${e['tipo'] ?? ''} · ${e['guardia'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          [
            if (hora != null) DateFormat('dd/MM HH:mm').format(hora),
            if (bloque.isNotEmpty) bloque,
            if (sub.isNotEmpty) sub,
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// Detalle completo de un registro (con fotos si la nube las tiene).
void mostrarEvento(BuildContext context, Map<String, dynamic> e) {
  final detalle = _detalle(e);
  final fotos = <String>[];
  final f1 = detalle['foto_url'];
  if (f1 is String && f1.isNotEmpty) fotos.add(f1);
  final f2 = detalle['fotos_url'];
  if (f2 is List) {
    for (final u in f2) {
      if (u is String && u.isNotEmpty) fotos.add(u);
    }
  }
  final hora = Cloud.horaEvento(e);
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(iconoEvento(e['tipo']?.toString()), color: AppColors.azulMarino, size: 34),
      title: Text('${e['tipo']}'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Guardia: ${e['guardia'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
          Text('Edificio: ${e['edificio'] ?? ''}${'${detalle['bloque'] ?? ''}'.isEmpty ? '' : ' · ${detalle['bloque']}'}',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          if (hora != null)
            Text('Fecha: ${DateFormat('dd/MM/yyyy HH:mm').format(hora)}',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          for (final entry in detalle.entries)
            if ('${entry.value}'.trim().isNotEmpty && !_ocultos.contains(entry.key))
              Padding(padding: const EdgeInsets.only(bottom: 3), child: Text('${entry.key}: ${entry.value}')),
          for (final u in fotos)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(u,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const SizedBox(height: 40, child: Center(child: Text('Foto no disponible')))),
              ),
            ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar'))],
    ),
  );
}
