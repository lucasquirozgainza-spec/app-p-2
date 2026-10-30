import 'package:flutter/material.dart';

/// Panel de FIRMA con el dedo. Guarda los trazos como texto compacto
/// ("x,y x,y|x,y ...", coordenadas 0-1000), que ocupa unos pocos KB en la nube
/// y se dibuja igual en el monitor y en el informe mensual.
class FirmaPad extends StatefulWidget {
  final ValueChanged<String?> onChanged; // null = sin firma
  const FirmaPad({super.key, required this.onChanged});

  @override
  State<FirmaPad> createState() => _FirmaPadState();
}

class _FirmaPadState extends State<FirmaPad> {
  final List<List<Offset>> _trazos = [];
  Size _tam = Size.zero;

  /// Texto compacto de la firma (null si está vacía o es solo un punto).
  String? get _texto {
    final puntos = _trazos.fold<int>(0, (a, t) => a + t.length);
    if (puntos < 8 || _tam.width <= 0) return null;
    String n(double v, double max) => (v / max * 1000).clamp(0, 1000).round().toString();
    return _trazos
        .where((t) => t.length > 1)
        .map((t) => t.map((p) => '${n(p.dx, _tam.width)},${n(p.dy, _tam.height)}').join(' '))
        .join('|');
  }

  void _avisar() => widget.onChanged(_texto);

  void _borrar() {
    setState(() => _trazos.clear());
    _avisar();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (ctx, c) {
        _tam = Size(c.maxWidth, 180);
        return Container(
          height: 180,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.black26),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            // Los arrastres dentro del panel no mueven la pantalla (solo dibujan).
            child: GestureDetector(
              onVerticalDragUpdate: (_) {},
              onHorizontalDragUpdate: (_) {},
              child: Listener(
              onPointerDown: (d) => setState(() => _trazos.add([d.localPosition])),
              onPointerMove: (d) {
                final p = d.localPosition;
                if (_trazos.isEmpty || p.dx < 0 || p.dy < 0 || p.dx > _tam.width || p.dy > _tam.height) return;
                final t = _trazos.last;
                // menos puntos = firma más liviana (solo si se movió ~2 px)
                if (t.isEmpty || (t.last - p).distance > 2) setState(() => t.add(p));
              },
              onPointerUp: (_) => _avisar(),
              child: CustomPaint(
                size: Size(c.maxWidth, 180),
                painter: _FirmaPainter(_trazos),
                child: _trazos.isEmpty
                    ? const Center(
                        child: Text('Firma aquí con el dedo', style: TextStyle(color: Colors.black38, fontSize: 16)),
                      )
                    : null,
              ),
            ),
            ),
          ),
        );
      }),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: _trazos.isEmpty ? null : _borrar,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Borrar y firmar de nuevo'),
        ),
      ),
    ]);
  }
}

class _FirmaPainter extends CustomPainter {
  final List<List<Offset>> trazos;
  _FirmaPainter(this.trazos);

  @override
  void paint(Canvas canvas, Size size) {
    // línea de firma
    final guia = Paint()
      ..color = Colors.black12
      ..strokeWidth = 1;
    canvas.drawLine(Offset(16, size.height - 36), Offset(size.width - 16, size.height - 36), guia);
    final p = Paint()
      ..color = const Color(0xFF111418)
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final t in trazos) {
      if (t.length == 1) {
        canvas.drawCircle(t.first, 1.3, p..style = PaintingStyle.fill);
        p.style = PaintingStyle.stroke;
        continue;
      }
      final path = Path()..moveTo(t.first.dx, t.first.dy);
      for (final q in t.skip(1)) {
        path.lineTo(q.dx, q.dy);
      }
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(covariant _FirmaPainter old) => true;
}
