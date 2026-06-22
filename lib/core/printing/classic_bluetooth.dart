import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Un dispositivo Bluetooth pareado, con su capacidad Classic/SPP.
@immutable
class ClassicBtDevice {
  const ClassicBtDevice({
    required this.name,
    required this.address,
    required this.hasSpp,
  });

  final String name;
  final String address;

  /// El equipo expone el perfil serie (SPP/RFCOMM) → imprimible por Classic.
  /// Si es `false` estando pareado, probablemente sea BLE-only (usar GATT).
  final bool hasSpp;
}

/// Evento de cambio de estado del enlace Classic, por dirección MAC.
@immutable
class ClassicBtEvent {
  const ClassicBtEvent({required this.address, required this.connected});
  final String address;
  final bool connected;
}

/// Acceso al transporte **Classic / RFCOMM (SPP)** nativo (Android).
///
/// Es el complemento del camino BLE (`flutter_blue_plus`): se usa para Fase 0
/// (saber qué impresoras exponen Classic) y como backend de impresión cuando el
/// equipo lo soporta (más rápido que BLE y única vía para impresoras
/// Classic-only). Ver `ClassicBtPlugin.kt`.
///
/// Fuera de Android **todo es no-op**: iOS no expone Classic/SPP a apps de
/// terceros (solo BLE o MFi), y macOS/Windows usan su propio camino. Los
/// métodos devuelven listas vacías / `false` / lanzan según corresponda.
class ClassicBluetooth {
  ClassicBluetooth._();

  static const MethodChannel _channel = MethodChannel('mangopos/classic_bt');
  static const EventChannel _events = EventChannel('mangopos/classic_bt/events');

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get isSupportedPlatform => _isAndroid;

  /// Stream de cambios de estado del enlace (por MAC). Vacío fuera de Android.
  static Stream<ClassicBtEvent> get events {
    if (!_isAndroid) return const Stream<ClassicBtEvent>.empty();
    return _events.receiveBroadcastStream().map((e) {
      final m = (e as Map).cast<dynamic, dynamic>();
      return ClassicBtEvent(
        address: m['address']?.toString() ?? '',
        connected: m['connected'] == true,
      );
    });
  }

  /// Dispositivos pareados con su capacidad SPP. Vacío fuera de Android o si
  /// falta el permiso BLUETOOTH_CONNECT.
  static Future<List<ClassicBtDevice>> bondedDevices() async {
    if (!_isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('bondedDevices');
      if (raw == null) return const [];
      return raw.map((e) {
        final m = (e as Map).cast<dynamic, dynamic>();
        return ClassicBtDevice(
          name: m['name']?.toString() ?? '',
          address: m['address']?.toString() ?? '',
          hasSpp: m['hasSpp'] == true,
        );
      }).toList(growable: false);
    } catch (e) {
      debugPrint('[ClassicBt] bondedDevices falló: $e');
      return const [];
    }
  }

  /// `true` si [address] está pareado y expone SPP (→ preferir Classic).
  static Future<bool> isBondedSpp(String address) async {
    if (!_isAndroid) return false;
    final a = address.trim();
    if (a.isEmpty) return false;
    final devices = await bondedDevices();
    return devices.any(
      (d) => d.hasSpp && d.address.toUpperCase() == a.toUpperCase(),
    );
  }

  /// Abre el socket RFCOMM. Lanza si falla (el manager lo trata como
  /// fallo de conexión y reintenta con backoff).
  static Future<void> connect(String address) async {
    if (!_isAndroid) {
      throw UnsupportedError('Classic BT solo está disponible en Android');
    }
    await _channel.invokeMethod<void>('connect', {'address': address});
  }

  /// Escribe los bytes por el socket. Lanza si el enlace se cayó.
  static Future<void> write(String address, List<int> data) async {
    if (!_isAndroid) {
      throw UnsupportedError('Classic BT solo está disponible en Android');
    }
    await _channel.invokeMethod<void>('write', {
      'address': address,
      'data': Uint8List.fromList(data),
    });
  }

  static Future<void> disconnect(String address) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('disconnect', {'address': address});
    } catch (e) {
      debugPrint('[ClassicBt] disconnect falló (ignorado): $e');
    }
  }

  static Future<bool> isConnected(String address) async {
    if (!_isAndroid) return false;
    try {
      return await _channel
              .invokeMethod<bool>('isConnected', {'address': address}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
