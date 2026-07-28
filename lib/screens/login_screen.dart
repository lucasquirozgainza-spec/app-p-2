import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../theme.dart';

/// Login SOLO de administrador (para entrar a Configuración).
/// Devuelve true por Navigator.pop si el acceso fue válido.
class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});
  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  final _user = TextEditingController(text: 'admin');
  final _pass = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  Future<void> _ingresar() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final ok = await AuthService.verifyAdmin(_user.text, _pass.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() => _error = 'Usuario o contrasena de administrador incorrectos');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.azulMarino,
      appBar: AppBar(title: const Text('Acceso administrador')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.admin_panel_settings, size: 48, color: AppColors.azulMarino),
                    const SizedBox(height: 12),
                    const Text('Solo administrador',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _user,
                      decoration: const InputDecoration(labelText: 'Usuario', prefixIcon: Icon(Icons.person_outline)),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _pass,
                      obscureText: _obscure,
                      onSubmitted: (_) => _ingresar(),
                      decoration: InputDecoration(
                        labelText: 'Contrasena',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: AppColors.rojo, fontWeight: FontWeight.w600)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _loading ? null : _ingresar,
                      child: _loading
                          ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                          : const Text('Ingresar'),
                    ),
                    const SizedBox(height: 8),
                    const Text('Por defecto: admin / admin123', style: TextStyle(color: Colors.black45, fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
