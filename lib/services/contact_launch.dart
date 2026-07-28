import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Utilidades para llamar y abrir WhatsApp (Bolivia, prefijo +591).
class Contacto {
  /// Normaliza a solo dígitos y antepone 591 si son 8 dígitos (celular BO).
  static String _normalize(String tel) {
    var d = tel.replaceAll(RegExp(r'[^0-9]'), '');
    if (d.length == 8) d = '591$d';
    return d;
  }

  static Future<void> llamar(BuildContext context, String tel) async {
    final clean = tel.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return _aviso(context, 'Sin numero de telefono');
    final uri = Uri.parse('tel:$clean');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _aviso(context, 'No se pudo iniciar la llamada');
    }
  }

  static Future<void> whatsapp(BuildContext context, String tel,
      {String mensaje = ''}) async {
    final d = _normalize(tel);
    if (d.isEmpty) return _aviso(context, 'Sin numero de WhatsApp');
    final url = 'https://wa.me/$d${mensaje.isNotEmpty ? '?text=${Uri.encodeComponent(mensaje)}' : ''}';
    if (!await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
      _aviso(context, 'No se pudo abrir WhatsApp');
    }
  }

  static void _aviso(BuildContext context, String m) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }
}
