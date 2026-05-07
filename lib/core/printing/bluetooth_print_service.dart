import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
// flutter_blue_plus 2.x oficial NO soporta Windows. Usamos el wrapper
// community `flutter_blue_plus_windows` que re-exporta todas las APIs de
// flutter_blue_plus en plataformas no-Windows y provee implementacion
// nativa win_ble_plus en Windows. Funciona transparente — el resto del
// codigo (BluetoothDevice, BluetoothCharacteristic, etc.) sigue igual.
import 'package:flutter_blue_plus_windows/flutter_blue_plus_windows.dart';

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

  // Hard-banned characteristic UUIDs: típicamente notify-only o de
  // configuración interna (DFU, OTA). Si el fallback intenta usarlas
  // como write, la impresora acepta los bytes pero nunca imprime.
  // Lista vacía por ahora — se va llenando cuando identifiquemos modelos
  // problemáticos en campo.
  static const _bannedCharacteristicUuids = <String>{};

  static void _log(String msg) {
    debugPrint('[BluetoothPrint] $msg');
  }

  static Future<void> printRaw({
    required String remoteId,
    required List<int> data,
    Duration connectTimeout = const Duration(seconds: 12),
    // Tiempo de espera tras el último write antes de desconectar. Algunas
    // térmicas (2Connect POS8001 V7, Munbyn, EPSON BLE económicos) procesan
    // el buffer despacio y abortan el job si la conexión cierra antes.
    // 1500ms cubre el peor caso observado; subir si reportes futuros indican
    // cortes parciales.
    Duration postFlushDelay = const Duration(milliseconds: 1500),
  }) async {
    _log('printRaw start: remoteId=$remoteId bytes=${data.length}');
    final device = BluetoothDevice.fromId(remoteId);
    _log('platformName="${device.platformName}" connected=${device.isConnected}');

    if (!device.isConnected) {
      _log('connecting (timeout=${connectTimeout.inSeconds}s)…');
      // flutter_blue_plus 1.x no acepta `license` (parametro 2.x-only).
      await device.connect(
        timeout: connectTimeout,
        autoConnect: false,
      );
      _log('connected.');
    }

    try {
      if (Platform.isAndroid) {
        try {
          final mtu = await device.requestMtu(247);
          _log('Android MTU negotiated: $mtu');
        } catch (e) {
          _log('Android requestMtu failed (sigue con default): $e');
        }
      }

      final services = await device.discoverServices();
      _log('services discovered: ${services.length}');
      for (final svc in services) {
        final chars = svc.characteristics
            .map((c) {
              final p = c.properties;
              final flags = <String>[
                if (p.write) 'W',
                if (p.writeWithoutResponse) 'Wnr',
                if (p.read) 'R',
                if (p.notify) 'N',
                if (p.indicate) 'I',
              ].join('|');
              return '${c.uuid.str}[$flags]';
            })
            .join(', ');
        _log('  svc ${svc.uuid.str} -> [$chars]');
      }

      BluetoothCharacteristic? writeChar;
      String? matchedVia;

      // 1. Pase priorizado: matches contra _knownServiceUuids en orden.
      for (final svcUuid in _knownServiceUuids) {
        for (final svc in services) {
          if (svc.uuid.str.toLowerCase() != svcUuid) continue;
          for (final c in svc.characteristics) {
            if (_bannedCharacteristicUuids.contains(c.uuid.str.toLowerCase())) {
              continue;
            }
            if (c.properties.writeWithoutResponse || c.properties.write) {
              writeChar = c;
              matchedVia = 'known_service:$svcUuid';
              break;
            }
          }
          if (writeChar != null) break;
        }
        if (writeChar != null) break;
      }

      // 2. Fallback: cualquier characteristic con write, ignorando los
      //    listados como banned. Preferimos writeWithoutResponse cuando
      //    está disponible — es lo que casi todas las térmicas BLE usan.
      if (writeChar == null) {
        for (final svc in services) {
          for (final c in svc.characteristics) {
            if (_bannedCharacteristicUuids.contains(c.uuid.str.toLowerCase())) {
              continue;
            }
            if (c.properties.writeWithoutResponse) {
              writeChar = c;
              matchedVia = 'fallback_wnr:${svc.uuid.str}';
              break;
            }
          }
          if (writeChar != null) break;
        }
      }
      if (writeChar == null) {
        for (final svc in services) {
          for (final c in svc.characteristics) {
            if (_bannedCharacteristicUuids.contains(c.uuid.str.toLowerCase())) {
              continue;
            }
            if (c.properties.write) {
              writeChar = c;
              matchedVia = 'fallback_w:${svc.uuid.str}';
              break;
            }
          }
          if (writeChar != null) break;
        }
      }

      if (writeChar == null) {
        _log('NO writable characteristic found. Aborting.');
        throw Exception(
          'La impresora Bluetooth no expone un canal de escritura compatible.',
        );
      }

      _log(
        'selected char ${writeChar.uuid.str} via $matchedVia '
        '(svc ${writeChar.serviceUuid.str})',
      );

      final mtu = device.mtuNow > 23 ? device.mtuNow - 3 : 20;
      final preferWithoutResponse = writeChar.properties.writeWithoutResponse;
      _log(
        'effective MTU=${device.mtuNow} chunkSize=$mtu '
        'mode=${preferWithoutResponse ? "writeWithoutResponse" : "write"}',
      );

      final chunkCount = (data.length / mtu).ceil();
      _log('writing $chunkCount chunks…');

      for (var i = 0; i < data.length; i += mtu) {
        final end = (i + mtu < data.length) ? i + mtu : data.length;
        await writeChar.write(
          data.sublist(i, end),
          withoutResponse: preferWithoutResponse,
        );
      }
      _log('all chunks written. Waiting ${postFlushDelay.inMilliseconds}ms before disconnect.');

      // Algunos modelos cortan el papel a destiempo o abortan el job si
      // desconectamos demasiado rápido tras el último write.
      await Future.delayed(postFlushDelay);
      _log('printRaw OK.');
    } finally {
      try {
        await device.disconnect();
        _log('disconnected.');
      } catch (e) {
        _log('disconnect failed (no critico): $e');
      }
    }
  }
}
