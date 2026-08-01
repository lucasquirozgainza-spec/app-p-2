import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'theme.dart';
import 'db/database_helper.dart';
import 'services/app_state.dart';
import 'services/retention.dart';
import 'services/notifications_service.dart';
import 'services/cloud.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CondoControlApp());
}

class CondoControlApp extends StatelessWidget {
  const CondoControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OSIRIS',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const _Boot(),
    );
  }
}

class _Boot extends StatefulWidget {
  const _Boot();
  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Solo lo imprescindible antes de mostrar la app (rapido):
    await initializeDateFormatting('es', null);
    await DB.instance.database;
    await AppState.instance.loadEdificio();
    await AppState.instance.restaurarOperador();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
    // El resto corre en segundo plano para no demorar el arranque.
    _tareasEnSegundoPlano();
  }

  void _tareasEnSegundoPlano() async {
    try {
      await Retention.purgar();
    } catch (_) {}
    try {
      await Cloud.init();
      await Cloud.heartbeat();
    } catch (_) {}
    try {
      await Notificaciones.programarRondas();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.azulMarino,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.apartment_rounded, color: Colors.white, size: 72),
            SizedBox(height: 16),
            Text('OSIRIS',
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
            SizedBox(height: 24),
            CircularProgressIndicator(color: Colors.white),
          ],
        ),
      ),
    );
  }
}
