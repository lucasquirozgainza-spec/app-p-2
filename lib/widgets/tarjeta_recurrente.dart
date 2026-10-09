import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../services/camara.dart';
import '../services/ocr_service.dart';
import '../theme.dart';

/// Tarjeta de acceso entregada a una visita recurrente.
class TarjetaEntregada {
  final String? foto;   // ruta de la foto de la tarjeta (null = sin tarjeta)
  final String numero;  // número leído por OCR o escrito
  const TarjetaEntregada(this.foto, this.numero);
  bool get hay => foto != null || numero.isNotEmpty;
  static const ninguna = TarjetaEntregada(null, '');
}

/// Al marcar el INGRESO de una visita recurrente: si el edificio usa tarjetas
/// de acceso, pregunta si se le entrega una; si sí, foto a la tarjeta y el OCR
/// lee el número (se puede corregir). Devuelve null si el guardia cancela.
Future<TarjetaEntregada?> pedirTarjetaRecurrente(BuildContext context, String nombre) async {
  final s = AppState.instance;
  if (!s.campoVisita('v_tarjeta')) return TarjetaEntregada.ninguna; // edificio sin tarjetas
  final dar = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      icon: const Icon(Icons.badge, color: AppColors.azulMarino, size: 34),
      title: Text('Ingreso de $nombre'),
      content: const Text('¿Le entregas una tarjeta de acceso?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Sin tarjeta')),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.photo_camera),
          label: const Text('Foto a la tarjeta'),
        ),
      ],
    ),
  );
  if (dar == null) return null;
  if (!dar) return TarjetaEntregada.ninguna;
  if (!context.mounted) return null;
  final res = await Camara.tomar(context, multi: false, album: 'OSIRIS Tarjetas', documento: true);
  if (res == null || res.isEmpty || !context.mounted) return null;
  final foto = res.first;
  final dig = s.tarjetaDigitos;
  // Lectura del número (unos segundos) con aviso en pantalla.
  showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
          content: Row(children: [CircularProgressIndicator(), SizedBox(width: 16), Expanded(child: Text('Leyendo el número…'))])));
  String? leido;
  try {
    leido = await OcrService.leerNumero(foto, digitos: dig).timeout(const Duration(seconds: 12));
  } catch (_) {}
  if (!context.mounted) return null;
  Navigator.pop(context); // cierra "Leyendo…"
  final ctrl = TextEditingController(text: (leido != null && leido.length == dig) ? leido : '');
  final numero = await showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Número de la tarjeta'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (ctrl.text.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('No se pudo leer: escríbelo o vuelve a intentar.', style: TextStyle(color: AppColors.rojo)),
          ),
        TextField(
          controller: ctrl,
          autofocus: ctrl.text.isEmpty,
          keyboardType: TextInputType.number,
          maxLength: dig,
          decoration: InputDecoration(labelText: 'N° de tarjeta ($dig dígitos)', prefixIcon: const Icon(Icons.pin)),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Confirmar ingreso')),
      ],
    ),
  );
  if (numero == null) return null;
  return TarjetaEntregada(foto, numero);
}

/// Al marcar la SALIDA: si se le entregó tarjeta, pregunta si la devolvió.
/// Devuelve null si el guardia cancela.
Future<bool?> preguntarDevolucion(BuildContext context, String nombre, String numero) {
  return showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      icon: const Icon(Icons.badge, color: AppColors.azulMarino, size: 36),
      title: const Text('Devolución de tarjeta'),
      content: Text('¿$nombre devolvió la tarjeta${numero.isEmpty ? '' : ' N° $numero'}?'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('NO devolvió', style: TextStyle(color: AppColors.rojo))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sí, devolvió')),
      ],
    ),
  );
}
