import 'package:flutter/material.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'app_state.dart';
import 'contact_launch.dart';

/// Notifica al administrador cuando ocurre un incidente.
/// Métodos: correo automático (SMTP), WhatsApp de un toque, o ambos.
class NotifyService {
  static Future<void> incidente(BuildContext context, {
    required String tipo,
    required String lugar,
    required String descripcion,
    required String guardia,
  }) async {
    final s = AppState.instance;
    final mensaje =
        '🚨 INCIDENTE - ${s.edificioNombre}\n'
        'Tipo: $tipo\n'
        'Lugar: $lugar\n'
        'Guardia: $guardia\n'
        'Descripcion: $descripcion';

    final metodo = s.notifMetodo;
    if (metodo == 'ninguno') return;

    // WhatsApp de un toque (primero: es lo inmediato para el guardia).
    if ((metodo == 'whatsapp' || metodo == 'ambos') && s.adminWhatsapp.isNotEmpty) {
      if (context.mounted) {
        await Contacto.whatsapp(context, s.adminWhatsapp, mensaje: mensaje);
      }
    }

    // Correo automático EN SEGUNDO PLANO y con tope de tiempo: sin internet no
    // deja el formulario colgado. El aviso sale en la barra inferior al terminar.
    if ((metodo == 'email' || metodo == 'ambos') &&
        s.adminEmail.isNotEmpty && s.senderEmail.isNotEmpty && s.senderPass.isNotEmpty) {
      final messenger = context.mounted ? ScaffoldMessenger.maybeOf(context) : null;
      () async {
        final ok = await _enviarEmail(
          de: s.senderEmail, clave: s.senderPass, para: s.adminEmail,
          asunto: 'Incidente - ${s.edificioNombre} ($tipo)', cuerpo: mensaje,
        ).timeout(const Duration(seconds: 25), onTimeout: () => false);
        messenger?.showSnackBar(SnackBar(
          content: Text(ok ? 'Aviso enviado al correo del admin' : 'No se pudo enviar el correo (revisa internet/config)'),
          backgroundColor: ok ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
        ));
      }();
    }
  }

  static Future<bool> _enviarEmail({
    required String de,
    required String clave,
    required String para,
    required String asunto,
    required String cuerpo,
  }) async {
    try {
      final server = gmail(de, clave);
      final message = Message()
        ..from = Address(de, 'OSIRIS Seguridad')
        ..recipients.add(para)
        ..subject = asunto
        ..text = cuerpo;
      await send(message, server);
      return true;
    } catch (_) {
      return false;
    }
  }
}
