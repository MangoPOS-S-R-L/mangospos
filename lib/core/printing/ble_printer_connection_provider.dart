import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ble_printer_connection_manager.dart';

/// Estado agregado de las conexiones BLE para el badge de la UI.
enum BlePrinterOverall {
  /// No hay impresoras BT persistentes configuradas.
  idle,

  /// Todas las impresoras BT deseadas están conectadas.
  connected,

  /// Al menos una está conectando o reconectando.
  reconnecting,
}

/// Snapshots `remoteId → estado` de las conexiones BLE persistentes
/// ([BlePrinterConnectionManager]). Emite el estado actual al suscribirse y
/// cada cambio posterior, para que la UI muestre conectado/reconectando/sin
/// impresora (PRD BT — observabilidad).
final blePrinterStatesProvider =
    StreamProvider.autoDispose<Map<String, BleConnState>>((ref) async* {
  final mgr = BlePrinterConnectionManager.instance;
  yield mgr.states;
  yield* mgr.stateStream;
});

/// Estado agregado derivado, listo para pintar un badge único.
final blePrinterOverallProvider =
    Provider.autoDispose<BlePrinterOverall>((ref) {
  final states = ref.watch(blePrinterStatesProvider).value;
  if (states == null || states.isEmpty) return BlePrinterOverall.idle;
  if (states.values.every((s) => s == BleConnState.connected)) {
    return BlePrinterOverall.connected;
  }
  return BlePrinterOverall.reconnecting;
});
