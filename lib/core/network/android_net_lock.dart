import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Prioriza la impresión por red en Android tomando locks del radio WiFi.
///
/// Android, por ahorro de energía, rompe la impresión por red/subredes de dos
/// formas que este helper mitiga (ver `MainActivity.kt`):
///
///   1. **MulticastLock** — el driver WiFi descarta el tráfico multicast
///      entrante salvo que la app mantenga un `MulticastLock`. Sin él, el
///      descubrimiento mDNS (impresoras AirPrint/IPP y print agents
///      `_mangoprint._tcp`) regresa vacío aunque el equipo esté en la LAN.
///      Se toma SOLO durante una pasada de descubrimiento.
///
///   2. **WifiLock (alto rendimiento)** — el radio entra en power-save al
///      inactivarse la pantalla, lo que hace que el primer `Socket.connect` a
///      la térmica tras un rato falle/tarde. Se mantiene durante toda la
///      sesión POS activa (lo gobierna el heartbeat scheduler: acquire en
///      `start()`, release en `stop()`).
///
/// Fuera de Android (iOS/desktop/web) **todo es no-op**: esas plataformas no
/// filtran multicast por defecto ni necesitan el lock, así que cada método
/// retorna sin tocar nada. Cualquier fallo del canal nativo se traga
/// silenciosamente — el lock es una mejora, nunca un requisito para imprimir.
class AndroidNetLock {
  AndroidNetLock._();

  static const MethodChannel _channel = MethodChannel('mangopos/net_lock');

  /// Solo Android tiene el comportamiento de power-save/multicast a mitigar.
  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  // El conteo por referencia del lado Dart evita ida y vuelta innecesaria al
  // canal nativo cuando hay descubrimientos mDNS solapados (el scan unificado
  // lanza varios en paralelo). El lado nativo también cuenta, así que esto es
  // defensa en profundidad, no la única barrera.
  static int _multicastRefs = 0;
  static int _wifiRefs = 0;

  static Future<void> acquireMulticastLock() async {
    if (!_isAndroid) return;
    _multicastRefs++;
    if (_multicastRefs == 1) {
      await _invoke('acquireMulticastLock');
    }
  }

  static Future<void> releaseMulticastLock() async {
    if (!_isAndroid) return;
    if (_multicastRefs == 0) return;
    _multicastRefs--;
    if (_multicastRefs == 0) {
      await _invoke('releaseMulticastLock');
    }
  }

  /// Ejecuta [action] con el MulticastLock tomado y lo libera al terminar,
  /// pase lo que pase. Úsalo alrededor de cualquier bloque mDNS.
  static Future<T> withMulticastLock<T>(Future<T> Function() action) async {
    await acquireMulticastLock();
    try {
      return await action();
    } finally {
      await releaseMulticastLock();
    }
  }

  static Future<void> acquireWifiLock() async {
    if (!_isAndroid) return;
    _wifiRefs++;
    if (_wifiRefs == 1) {
      await _invoke('acquireWifiLock');
    }
  }

  static Future<void> releaseWifiLock() async {
    if (!_isAndroid) return;
    if (_wifiRefs == 0) return;
    _wifiRefs--;
    if (_wifiRefs == 0) {
      await _invoke('releaseWifiLock');
    }
  }

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } catch (e) {
      // El lock es best-effort: si el canal no está disponible (build viejo,
      // plataforma sin la implementación) seguimos imprimiendo sin la mejora.
      debugPrint('[AndroidNetLock] $method falló (ignorado): $e');
    }
  }
}
