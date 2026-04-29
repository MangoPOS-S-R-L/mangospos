import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// PRD 5 F3: imprime ESC/POS directo a una impresora Bluetooth via GATT.
/// Soporta Mac, iOS y Android sin necesidad del agente Node.js.
class BluetoothPrintService {
  // Service UUIDs comunes en térmicas BLE (orden de preferencia).
  static const _knownServiceUuids = <String>[
    '49535343-fe7d-4ae5-8fa9-9fafd205e455', // ISSC / Microchip SPP
    '0000ffe0-0000-1000-8000-00805f9b34fb', // HM-10
    '000018f0-0000-1000-8000-00805f9b34fb', // POS-style notify/write
    '0000ff00-0000-1000-8000-00805f9b34fb', // genérico
  ];

  static Future<void> printRaw({
    required String remoteId,
    required List<int> data,
    Duration connectTimeout = const Duration(seconds: 12),
  }) async {
    final device = BluetoothDevice.fromId(remoteId);

    if (!device.isConnected) {
      await device.connect(
        license: License.free,
        timeout: connectTimeout,
        autoConnect: false,
      );
    }

    try {
      if (Platform.isAndroid) {
        try {
          await device.requestMtu(247);
        } catch (_) {}
      }

      final services = await device.discoverServices();

      BluetoothCharacteristic? writeChar;

      for (final svcUuid in _knownServiceUuids) {
        for (final svc in services) {
          if (svc.uuid.str.toLowerCase() != svcUuid) continue;
          for (final c in svc.characteristics) {
            if (c.properties.writeWithoutResponse || c.properties.write) {
              writeChar = c;
              break;
            }
          }
          if (writeChar != null) break;
        }
        if (writeChar != null) break;
      }

      if (writeChar == null) {
        for (final svc in services) {
          for (final c in svc.characteristics) {
            if (c.properties.writeWithoutResponse || c.properties.write) {
              writeChar = c;
              break;
            }
          }
          if (writeChar != null) break;
        }
      }

      if (writeChar == null) {
        throw Exception(
          'La impresora Bluetooth no expone un canal de escritura compatible.',
        );
      }

      final mtu = device.mtuNow > 23 ? device.mtuNow - 3 : 20;
      final preferWithoutResponse = writeChar.properties.writeWithoutResponse;

      for (var i = 0; i < data.length; i += mtu) {
        final end = (i + mtu < data.length) ? i + mtu : data.length;
        await writeChar.write(
          data.sublist(i, end),
          withoutResponse: preferWithoutResponse,
        );
      }

      // Pequeño flush para que la térmica termine de procesar antes de
      // desconectar (algunos modelos cortan el papel a destiempo si no).
      await Future.delayed(const Duration(milliseconds: 250));
    } finally {
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }
}
