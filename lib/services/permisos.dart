import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../theme.dart';

/// Manejo del permiso de cámara en todos los casos:
/// - concedido: sigue directo;
/// - rechazado: lo vuelve a pedir;
/// - rechazado "para siempre" o revocado desde Ajustes: explica y ofrece
///   abrir los Ajustes de la app (Android ya no muestra el diálogo del sistema).
class Permisos {
  static Future<bool> camara(BuildContext context) async {
    try {
      var st = await Permission.camera.status;
      if (st.isGranted || st.isLimited) return true;
      if (!st.isPermanentlyDenied && !st.isRestricted) {
        st = await Permission.camera.request();
        if (st.isGranted || st.isLimited) return true;
      }
      if (!context.mounted) return false;
      final ajustes = st.isPermanentlyDenied || st.isRestricted;
      final accion = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.no_photography_outlined, color: AppColors.rojo, size: 36),
          title: const Text('Permiso de cámara'),
          content: Text(ajustes
              ? 'OSIRIS no tiene permiso para usar la cámara. Actívalo en Ajustes → Permisos → Cámara.'
              : 'OSIRIS necesita la cámara para tomar las fotos de registro.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ajustes ? 'ajustes' : 'pedir'),
              child: Text(ajustes ? 'Abrir ajustes' : 'Permitir'),
            ),
          ],
        ),
      );
      if (accion == 'ajustes') {
        await openAppSettings();
        return false; // al volver, el guardia toca de nuevo la foto
      }
      if (accion == 'pedir') {
        final r = await Permission.camera.request();
        return r.isGranted || r.isLimited;
      }
      return false;
    } catch (_) {
      // Si el plugin de permisos falla, dejamos que la cámara lo intente
      // (el sistema pedirá el permiso por su cuenta).
      return true;
    }
  }
}
