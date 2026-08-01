import 'dart:convert';
import 'dart:io';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'app_state.dart';

/// Configuracion de un DVR/camara leida de un QR (formato Dahua DMSS/gDMSS).
class DvrConfig {
  String nombre;
  String usuario;
  String clave;
  int canales;
  int puerto;
  String serial; // serial P2P (no sirve para RTSP directo)
  DvrConfig({
    this.nombre = 'DVR',
    this.usuario = 'admin',
    this.clave = '',
    this.canales = 1,
    this.puerto = 554,
    this.serial = '',
  });
}

class Dvr {
  /// Lee el QR de una imagen (usa ML Kit, mismo motor del OCR).
  static Future<String?> leerQr(String path) async {
    final scanner = BarcodeScanner();
    try {
      final res = await scanner.processImage(InputImage.fromFilePath(path));
      if (res.isEmpty) return null;
      return res.first.rawValue;
    } catch (_) {
      return null;
    } finally {
      await scanner.close();
    }
  }

  /// Interpreta el contenido del QR de Dahua (gzip+base64 con un JSON).
  static DvrConfig? parseQr(String raw) {
    try {
      String texto = raw.trim();
      // Formato Dahua: base64 de un gzip que contiene un JSON.
      if (!texto.trimLeft().startsWith('[') && !texto.trimLeft().startsWith('{')) {
        try {
          final bytes = base64.decode(texto.replaceAll(RegExp(r'\s'), ''));
          final unzipped = gzip.decode(bytes);
          texto = utf8.decode(unzipped);
        } catch (_) {
          // No era gzip+base64; se intenta como JSON directo mas abajo.
        }
      }
      // Si NO es JSON (ej. QR de la etiqueta del equipo, que trae solo el
      // serial o un texto tipo "SN:xxxx"), lo tomamos como serial.
      if (!texto.trimLeft().startsWith('[') && !texto.trimLeft().startsWith('{')) {
        final sn = RegExp(r'([A-Z0-9]{10,})').firstMatch(texto.toUpperCase());
        return DvrConfig(nombre: 'DVR', serial: sn?.group(1) ?? texto.trim());
      }
      final data = jsonDecode(texto);
      final Map<String, dynamic> m = data is List ? Map<String, dynamic>.from(data.first) : Map<String, dynamic>.from(data);
      return DvrConfig(
        nombre: (m['deviceName'] ?? 'DVR').toString(),
        usuario: (m['userName'] ?? 'admin').toString(),
        clave: (m['passWord'] ?? '').toString(),
        canales: int.tryParse('${m['channelCount'] ?? 1}') ?? 1,
        puerto: 554, // RTSP siempre 554 (el 37777 del QR es el puerto SDK)
        serial: (m['ip'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Host activo según el modo: datos móviles (DDNS) o WiFi local.
  static String host(Map<String, dynamic> cam) {
    final local = (cam['host']?.toString() ?? '').trim();
    final remoto = (cam['host_remoto']?.toString() ?? '').trim();
    if (AppState.instance.camaraRemota) return remoto.isNotEmpty ? remoto : local;
    return local.isNotEmpty ? local : remoto;
  }

  /// URL RTSP en vivo (formato Dahua). subtype 0 = principal, 1 = secundaria.
  static String rtspVivo({
    required String host,
    int puerto = 554,
    required String usuario,
    required String clave,
    required int canal,
    int subtype = 0,
  }) {
    final u = Uri.encodeComponent(usuario);
    final c = Uri.encodeComponent(clave);
    return 'rtsp://$u:$c@$host:$puerto/cam/realmonitor?channel=$canal&subtype=$subtype';
  }

  /// URL RTSP de reproduccion de grabaciones (formato Dahua).
  static String rtspPlayback({
    required String host,
    int puerto = 554,
    required String usuario,
    required String clave,
    required int canal,
    required DateTime desde,
    required DateTime hasta,
  }) {
    String f(DateTime d) =>
        '${d.year}_${_2(d.month)}_${_2(d.day)}_${_2(d.hour)}_${_2(d.minute)}_${_2(d.second)}';
    final u = Uri.encodeComponent(usuario);
    final c = Uri.encodeComponent(clave);
    return 'rtsp://$u:$c@$host:$puerto/cam/playback?channel=$canal&starttime=${f(desde)}&endtime=${f(hasta)}';
  }

  static String _2(int n) => n.toString().padLeft(2, '0');
}
