import 'package:flutter/material.dart';
import '../theme.dart';

/// Modulo planificado para la siguiente version.
class PlaceholderScreen extends StatelessWidget {
  final String titulo;
  const PlaceholderScreen({super.key, required this.titulo});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(titulo)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.rocket_launch_outlined,
                  size: 72, color: AppColors.azulMarino),
              const SizedBox(height: 16),
              Text('Modulo "$titulo"',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Este modulo esta planificado para la proxima version. '
                'La base de datos ya esta preparada para recibirlo.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
