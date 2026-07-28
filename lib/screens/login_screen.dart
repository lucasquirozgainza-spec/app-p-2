import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/app_state.dart';
import '../theme.dart';
import 'inicio_turno_screen.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  Future<void> _ingresar() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final err = await AuthService.login(_user.text, _pass.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final s = AppState.instance;
    // Si no tiene turno activo, obligar registro de inicio de turno.
    if (s.turnoActivoId == null && s.userRol == 'guardia') {
      Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) => const InicioTurnoScreen()));
    } else {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const HomeScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.azulMarino,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.apartment_rounded, color: Colors.white, size: 64),
                const SizedBox(height: 12),
                const Text('CondoControl Pro',
                    style: TextStyle(
                        color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                Text(AppState.instance.edificioNombre,
                    style: const TextStyle(color: Colors.white70, fontSize: 15)),
                const SizedBox(height: 28),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        const Text('Iniciar Sesion',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 18),
                        TextField(
                          controller: _user,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Usuario',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
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
                          Text(_error!,
                              style: const TextStyle(color: AppColors.rojo, fontWeight: FontWeight.w600)),
                        ],
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _loading ? null : _ingresar,
                          child: _loading
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2.5))
                              : const Text('Ingresar'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Demo:  admin / admin123   ·   guardia / guardia123',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
