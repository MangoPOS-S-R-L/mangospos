import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Controla el Foreground Service que mantiene viva la conexión BLE con la
/// impresora en Android (PRD BT — Fase 1).
///
/// El servicio nativo ([PrinterForegroundService] en Kotlin) no posee el
/// socket: solo conserva el proceso de la app priorizado y muestra una
/// notificación persistente, para que el [BlePrinterConnectionManager] (que
/// vive en el isolate Dart) pueda sostener el GATT y reconectar con la pantalla
/// apagada / la app en background.
///
/// Fuera de Android **todo es no-op**: iOS/macOS/Windows no tienen el problema
/// de kill de proceso/Doze que esto mitiga, y la persistencia BLE allí (si se
/// habilita) usa otros mecanismos. Cualquier fallo del canal nativo se traga
/// silenciosamente — el servicio es una mejora de persistencia, nunca un
/// requisito para imprimir.
class AndroidPrinterForegroundService {
  AndroidPrinterForegroundService._();

  static const MethodChannel _channel =
      MethodChannel('mangopos/printer_fgs');

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Evita ir y volver al canal nativo si ya está corriendo/parado.
  static bool _running = false;

  static bool get isRunning => _running;

  /// Arranca el servicio si no está ya activo. Idempotente.
  static Future<void> start() async {
    if (!_isAndroid || _running) return;
    _running = true;
    await _invoke('start');
  }

  /// Detiene el servicio si está activo. Idempotente.
  static Future<void> stop() async {
    if (!_isAndroid || !_running) return;
    _running = false;
    await _invoke('stop');
  }

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } catch (e) {
      // Best-effort: si el canal no está disponible (build viejo o sin la
      // implementación nativa) seguimos imprimiendo, solo sin persistencia.
      debugPrint('[PrinterFGS] $method falló (ignorado): $e');
    }
  }
}
