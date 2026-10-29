import 'package:flutter/material.dart';
import '../services/contactos_repo.dart';
import '../theme.dart';

/// Campo de departamento con ayuda de escritura rapida en BLOQUES (chips):
/// al escribir muestra los deptos registrados como botoncitos para tocar.
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
  List<String> _sug = [];

  @override
  void initState() {
    super.initState();
    ContactosRepo.deptos().then((v) {
      if (mounted) setState(() => _todos = v);
    });
  }

  void _filtrar(String t) {
    final q = t.trim().toLowerCase();
    setState(() {
      _sug = q.isEmpty
          ? []
          : _todos.where((d) => d.toLowerCase().startsWith(q) && d.toLowerCase() != q).take(8).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          onChanged: _filtrar,
          decoration: InputDecoration(
            labelText: widget.label,
            prefixIcon: const Icon(Icons.meeting_room),
          ),
        ),
        if (_sug.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final d in _sug)
                ActionChip(
                  label: Text(d),
                  backgroundColor: AppColors.grisClaro,
                  onPressed: () {
                    widget.controller.text = d;
                    setState(() => _sug = []);
                    widget.onSelected?.call(d);
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }
}
