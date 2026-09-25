import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'theme.dart';
import 'db/database_helper.dart';
import 'services/app_state.dart';
import 'services/retention.dart';
import 'services/notifications_service.dart';
import 'services/camara.dart';
import 'services/cloud.dart';
import 'services/estructura.dart';
import 'services/sesion.dart';
import 'services/config_sync.dart';
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
      builder: (context, child) => _SinBarraSistema(child: child ?? const SizedBox()),
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
    // Cada paso protegido: si uno falla la app igual abre (antes un dato
    // dañado dejaba el celular trabado en esta pantalla para siempre).
    try { await initializeDateFormatting('es', null); } catch (_) {}
    try {
      await DB.instance.database;
      await AppState.instance.loadEdificio();
      await AppState.instance.restaurarOperador();
    } catch (_) {}
    // El id del celular ANTES del primer latido/evento (si no, se enviaban
    // con el id genérico "device" y se mezclaban los celulares).
    try { await Cloud.init(); } catch (_) {}
    // Vínculo del celular con su edificio/unidad (si ya fue vinculado).
    try {
      await Sesion.init();
      await Estructura.init();
      await AppState.instance.aplicarVinculo();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
    // El resto corre en segundo plano para no demorar el arranque.
    _tareasEnSegundoPlano();
  }

  void _tareasEnSegundoPlano() async {
    // Fotos de la cámara nativa que quedaron sin guardar porque Android
    // cerró la app por falta de memoria.
    try { await Camara.recuperarPerdidas(); } catch (_) {}
    try {
      await Sesion.revisar(forzar: true);
      await AppState.instance.aplicarVinculo();
      await Estructura.actualizar();
    } catch (_) {}
    try {
      await Cloud.heartbeat();
      await Cloud.vaciarCola(); // lo registrado sin señal
    } catch (_) {}
    // Aplicar config y contraseña de admin remotas (publicadas por el admin).
    try {
      await ConfigSync.aplicarRemota();
      await ConfigSync.aplicarAdminPassRemota();
      await ConfigSync.sincronizarGuardias();
    } catch (_) {}
    // La purga (local + nube) corre DESPUÉS de iniciar la nube, así el borrado
    // de fotos viejas en Supabase Storage se ejecuta cada vez que se abre la app.
    try {
      await Retention.purgar();
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

/// Android 15 dibuja la app DEBAJO de la barra de navegación del sistema
/// (pantalla completa obligatoria): los botones "Guardar" al final de los
/// formularios quedaban tapados. Se reserva ese espacio una sola vez para toda
/// la app, como en las versiones anteriores de Android.
class _SinBarraSistema extends StatelessWidget {
  final Widget child;
  const _SinBarraSistema({required this.child});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final b = mq.viewPadding.bottom;
    if (b <= 0) return child;
    final vi = mq.viewInsets;
    return ColoredBox(
      color: Colors.black,
      child: Padding(
        padding: EdgeInsets.only(bottom: b),
        child: MediaQuery(
          data: mq
              .removePadding(removeBottom: true)
              .removeViewPadding(removeBottom: true)
              // El teclado se mide desde el borde de la pantalla: se descuenta
              // lo ya reservado para no dejar un hueco sobre el teclado.
              .copyWith(viewInsets: vi.copyWith(bottom: math.max(0.0, vi.bottom - b))),
          child: child,
        ),
      ),
    );
  }
}
