import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus_windows/flutter_blue_plus_windows.dart';

import 'bluetooth_print_service.dart';
import 'classic_bluetooth.dart';

/// Qué transporte usa un enlace concreto.
enum PrinterTransportKind { ble, classic }

/// Abstracción de un enlace a una impresora, independiente del transporte
/// (BLE/GATT o Classic/RFCOMM). El [PrinterConnectionManager] orquesta estado,
/// reconexión y cola sobre esta interfaz sin saber qué transporte hay debajo.
abstract class PrinterLink {
  String get address;
  PrinterTransportKind get kind;

  /// Estado actual del enlace (lectura síncrona, para heartbeat/decisiones).
  bool get isConnected;

  /// Emite `true` al conectar y `false` al caerse. El manager reacciona a
  /// `false` para disparar la reconexión.
  Stream<bool> get connectionEvents;

  /// Establece el enlace. BLE: connect + discover + selección de characteristic;
  /// Classic: abre el socket RFCOMM. Lanza si falla.
  Future<void> connect({required Duration timeout});

  /// Escribe los bytes (cada transporte maneja su propio troceo/stream).
  Future<void> write(List<int> data);

  Future<void> disconnect();

  /// Libera recursos (suscripciones, controllers).
  Future<void> dispose();
}

/// Enlace BLE/GATT sobre `flutter_blue_plus`. Envuelve exactamente el camino
/// que antes vivía en el manager: connect → (MTU) → discover → seleccionar
/// characteristic → escribir en chunks de MTU.
class BleLink implements PrinterLink {
  BleLink(this._address) : _device = BluetoothDevice.fromId(_address);

  final String _address;
  final BluetoothDevice _device;
  BluetoothCharacteristic? _writeChar;
  bool _preferWithoutResponse = true;

  @override
  String get address => _address;

  @override
  PrinterTransportKind get kind => PrinterTransportKind.ble;

  @override
  bool get isConnected => _device.isConnected && _writeChar != null;

  @override
  Stream<bool> get connectionEvents => _device.connectionState
      .map((s) => s == BluetoothConnectionState.connected);

  @override
  Future<void> connect({required Duration timeout}) async {
    if (!_device.isConnected) {
      // flutter_blue_plus 1.x: sin `license` (param 2.x-only).
      await _device.connect(timeout: timeout, autoConnect: false);
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _device.requestMtu(247);
      } catch (_) {/* sigue con el MTU por defecto */}
    }
    final services = await _device.discoverServices();
    final selection = BluetoothPrintService.selectWriteCharacteristic(services);
    if (selection == null) {
      throw Exception(
        'La impresora BLE no expone un canal de escritura compatible.',
      );
    }
    _writeChar = selection.char;
    _preferWithoutResponse = selection.char.properties.writeWithoutResponse;
  }

  @override
  Future<void> write(List<int> data) async {
    final char = _writeChar;
    if (char == null) {
      throw StateError('BleLink.write sin characteristic (no conectado)');
    }
    final mtuNow = _device.mtuNow;
    final chunk = mtuNow > 23 ? mtuNow - 3 : 20;
    for (var i = 0; i < data.length; i += chunk) {
      final end = (i + chunk < data.length) ? i + chunk : data.length;
      await char.write(
        data.sublist(i, end),
        withoutResponse: _preferWithoutResponse,
      );
    }
  }

  @override
  Future<void> disconnect() async {
    _writeChar = null;
    try {
      if (_device.isConnected) await _device.disconnect();
    } catch (_) {/* best-effort */}
  }

  @override
  Future<void> dispose() async {
    // La suscripción a connectionState la cancela el manager; nada propio.
  }
}

/// Enlace Classic/RFCOMM (SPP) sobre el plugin nativo [ClassicBluetooth]
/// (Android). Más rápido que BLE para tickets largos y única vía para
/// impresoras Classic-only.
class ClassicLink implements PrinterLink {
  ClassicLink(this._address) {
    // Mantiene `_connected` al día para la lectura síncrona del manager.
    _sub = ClassicBluetooth.events
        .where((e) => e.address.toUpperCase() == _address.toUpperCase())
        .listen((e) {
      _connected = e.connected;
      if (!_controller.isClosed) _controller.add(e.connected);
    });
  }

  final String _address;
  bool _connected = false;
  StreamSubscription<ClassicBtEvent>? _sub;
  final StreamController<bool> _controller = StreamController<bool>.broadcast();

  @override
  String get address => _address;

  @override
  PrinterTransportKind get kind => PrinterTransportKind.classic;

  @override
  bool get isConnected => _connected;

  @override
  Stream<bool> get connectionEvents => _controller.stream;

  @override
  Future<void> connect({required Duration timeout}) async {
    await ClassicBluetooth.connect(_address).timeout(timeout);
    _connected = true;
  }

  @override
  Future<void> write(List<int> data) => ClassicBluetooth.write(_address, data);

  @override
  Future<void> disconnect() async {
    _connected = false;
    await ClassicBluetooth.disconnect(_address);
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}
