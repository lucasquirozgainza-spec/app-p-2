import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/app_state.dart';
import '../services/camara.dart';
import '../services/device_context.dart';
import '../services/presencia_service.dart';
import '../theme.dart';
import '../widgets/firma_pad.dart';

/// Pantalla de CONTROL DE PRESENCIA NOCTURNA. Se abre sola cuando suena la
/// alarma. No tiene botón para cerrar, posponer ni silenciar: la alarma sigue
/// hasta que el guardia firma y se toma una foto con la cámara frontal.
class PresenciaScreen extends StatefulWidget {
  final Verificacion v;
  const PresenciaScreen({super.key, required this.v});

  @override
  State<PresenciaScreen> createState() => _PresenciaScreenState();
}

class _PresenciaScreenState extends State<PresenciaScreen> {
  final DateTime _abierta = DateTime.now();
  String? _firma;
  String? _foto;
  String? _huella;
  bool _guardando = false;
  String? _error;
  Timer? _sonido;
  int _firmaKey = 0;

  @override
  void initState() {
    super.initState();
    Presencia.sobreBloqueo(true);
    // Si el guardia baja la cortina de notificaciones el sonido se corta:
    // cada 25 s se vuelve a activar mientras no complete la verificación.
    _sonido = Timer.periodic(const Duration(seconds: 25), (_) => Presencia.reactivarSonido(widget.v));
  }

  @override
  void dispose() {
    _sonido?.cancel();
    super.dispose();
  }

  Future<void> _tomarFoto() async {
    setState(() => _error = null);
    final r = await Camara.tomar(context, frontal: true);
    if (!mounted || r == null || r.isEmpty) return;
    final ruta = r.first;
    try {
      final f = File(ruta);
      // Solo una foto tomada AHORA (no una vieja de la galería).
      final mod = await f.lastModified();
      if (mod.isBefore(_abierta.subtract(const Duration(seconds: 5)))) {
        setState(() => _error = 'La foto debe tomarse ahora con la cámara.');
        return;
      }
      final huella = sha256.convert(await f.readAsBytes()).toString();
      if (await Presencia.fotoUsada(huella)) {
        setState(() => _error = 'Esa foto ya se usó en otra verificación. Toma una nueva.');
        return;
      }
      setState(() {
        _foto = ruta;
        _huella = huella;
      });
    } catch (_) {
      setState(() => _error = 'No se pudo leer la foto. Toma otra.');
    }
  }

  Future<void> _confirmar() async {
    final firma = _firma, foto = _foto, huella = _huella;
    if (firma == null) {
      setState(() => _error = 'Falta la firma.');
      return;
    }
    if (foto == null || huella == null) {
      setState(() => _error = 'Falta la foto.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      if (!await File(foto).exists()) {
        setState(() {
          _guardando = false;
          _foto = null;
          _error = 'La foto ya no está. Toma otra.';
        });
        return;
      }
      final gps = await DeviceContext.gps();
      final estado = await Presencia.completar(widget.v,
          firma: firma, foto: foto, huella: huella, abierta: _abierta, gps: gps);
      _sonido?.cancel();
      await Presencia.sobreBloqueo(false);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.verified, color: AppColors.verde, size: 56),
          title: const Text('VERIFICACIÓN COMPLETADA', textAlign: TextAlign.center),
          content: Text(
            estado == 'tardia'
                ? 'Se registró tu verificación fuera del tiempo máximo. Supervisión recibirá el aviso de respuesta tardía.'
                : 'Se registró tu verificación de presencia.',
            textAlign: TextAlign.center,
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Aceptar'))],
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = 'No se pudo guardar. Intenta de nuevo.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final hora = DateFormat('HH:mm').format(widget.v.t);
    final listo = _firma != null && _foto != null && !_guardando;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Presencia.intentoSalir(widget.v);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Completa la firma y la foto para detener la alarma.')));
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF14181C),
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 18, 16, 24), children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(colors: [Color(0xFF526A6C), Color(0xFF9F0500)]),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Row(children: [
                  Icon(Icons.alarm, color: Colors.white, size: 30),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text('CONTROL DE PRESENCIA NOCTURNA',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                ]),
                const SizedBox(height: 12),
                _dato('Guardia', s.userNombre ?? '-'),
                _dato('Edificio', s.edificioNombre),
                _dato('Puesto', s.bloque.isNotEmpty ? s.bloque : 'Puesto principal'),
                _dato('Activación', hora),
                const SizedBox(height: 10),
                const Text('Verificación obligatoria de presencia. Complete su registro para detener la alarma.',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
              ]),
            ),
            const SizedBox(height: 16),
            _tarjeta(
              '1. Firma',
              _firma != null,
              FirmaPad(key: ValueKey(_firmaKey), onChanged: (v) => setState(() => _firma = v)),
            ),
            const SizedBox(height: 12),
            _tarjeta(
              '2. Foto con la cámara frontal',
              _foto != null,
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (_foto != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(File(_foto!), height: 240, fit: BoxFit.cover),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _guardando ? null : _tomarFoto,
                  icon: const Icon(Icons.camera_front),
                  label: Text(_foto == null ? 'Tomar foto' : 'Repetir foto'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                ),
              ]),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 15, fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: listo ? _confirmar : null,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.verde,
                minimumSize: const Size.fromHeight(58),
                textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              child: _guardando
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                  : const Text('CONFIRMAR VERIFICACIÓN'),
            ),
            if (!listo && !_guardando)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Se habilita cuando estén la firma y la foto.',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _dato(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(children: [
          SizedBox(width: 92, child: Text(k, style: const TextStyle(color: Colors.white70))),
          Expanded(child: Text(v, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
        ]),
      );

  Widget _tarjeta(String titulo, bool ok, Widget hijo) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(titulo, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
            Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked, color: ok ? AppColors.verde : Colors.black26),
          ]),
          const SizedBox(height: 10),
          hijo,
        ]),
      );
}
