import 'package:flutter/material.dart';
import '../services/contactos_repo.dart';

/// Campo de departamento con ayuda de escritura rapida: al escribir sugiere
/// los deptos registrados del edificio. Escribe sobre el [controller] dado.
class DeptoField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final ValueChanged<String>? onSelected;
  const DeptoField({
    super.key,
    required this.controller,
    this.label = 'Departamento',
    this.onSelected,
  });

  @override
  State<DeptoField> createState() => _DeptoFieldState();
}

class _DeptoFieldState extends State<DeptoField> {
  List<String> _todos = [];

  @override
  void initState() {
    super.initState();
    ContactosRepo.deptos().then((v) {
      if (mounted) setState(() => _todos = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: widget.controller.text),
      optionsBuilder: (t) {
        final q = t.text.trim().toLowerCase();
        if (q.isEmpty) return const Iterable<String>.empty();
        return _todos.where((d) => d.toLowerCase().startsWith(q)).take(8);
      },
      onSelected: (v) {
        widget.controller.text = v;
        widget.onSelected?.call(v);
      },
      fieldViewBuilder: (context, textController, focusNode, onSubmit) {
        return TextField(
          controller: textController,
          focusNode: focusNode,
          // Reflejar lo escrito en el controller externo (fuente de datos).
          onChanged: (v) => widget.controller.text = v,
          decoration: InputDecoration(
            labelText: widget.label,
            prefixIcon: const Icon(Icons.meeting_room),
          ),
        );
      },
    );
  }
}
