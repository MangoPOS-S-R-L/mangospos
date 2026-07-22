import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Impresión USB (OTG) nativa en Android con escritura **síncrona y
/// verificada** — el reemplazo del `write()` de `flutter_usb_printer`.
///
/// Por qué existe: el plugin dispara el `bulkTransfer` en un Thread suelto y
/// devuelve `true` de inmediato, así que el `await` en Dart no espera nada;
/// al cerrar la conexión justo después, el ticket sale por la mitad. Además
/// manda el buffer completo en una sola llamada (Android < 9 trunca a 16 KB
/// en silencio) e ignora las transferencias parciales.
///
/// El lado nativo (`UsbRawPrinterPlugin.kt`, canal `mangopos/usb_raw_printer`)
/// trocea en bloques de 4 KB, avanza por los bytes realmente aceptados y solo
/// responde cuando el último byte fue entregado (o con error si no). También
/// gestiona el diálogo de permiso USB del sistema.
///
/// Fuera de Android todo lanza [UnsupportedError]; los callers ya gatean por
/// plataforma.
class AndroidUsbRawPrinter {
  AndroidUsbRawPrinter._();

  static const MethodChannel _channel =
      MethodChannel('mangopos/usb_raw_printer');

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Lista las impresoras USB conectadas (dispositivos con endpoint bulk OUT).
  /// Cada mapa trae `vendorId`, `productId`, `manufacturer`, `productName`.
  static Future<List<Map<String, dynamic>>> listDevices() async {
    _ensureAndroid();
    final raw = await _channel.invokeMethod<List<dynamic>>('listDevices');
    return (raw ?? const [])
        .whereType<Map>()
        .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  /// Escribe [data] completo a la impresora `vendorId:productId`. Devuelve
  /// solo cuando el dispositivo aceptó el último byte; lanza [PlatformException]
  /// (códigos `usb_device_not_found`, `usb_permission_denied`,
  /// `usb_transfer_failed`, …) si algo falla.
  static Future<void> write({
    required int vendorId,
    required int productId,
    required Uint8List data,
  }) async {
    _ensureAndroid();
    await _channel.invokeMethod<bool>('write', {
      'vendorId': vendorId,
      'productId': productId,
      'data': data,
    });
  }

  static void _ensureAndroid() {
    if (!isSupported) {
      throw UnsupportedError(
        'AndroidUsbRawPrinter solo está disponible en Android',
      );
    }
  }
}
