import 'package:flutter/material.dart';

/// Aviso flotante que aparece ARRIBA (no tapa los botones de guardar/registrar
/// que están abajo). Se cierra solo.
class TopToast {
  static void show(BuildContext context, String mensaje,
      {Color color = const Color(0xFF2E7D32), IconData icon = Icons.check_circle}) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final top = MediaQuery.of(ctx).padding.top + 10;
        return Positioned(
          top: top,
          left: 14,
          right: 14,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 3))],
              ),
              child: Row(children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(mensaje,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 2200), () {
      try { entry.remove(); } catch (_) {}
    });
  }
}
