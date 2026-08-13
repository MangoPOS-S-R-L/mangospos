// Qué "idioma" habla cada impresora.
//
// La inmensa mayoría de las térmicas del mercado son ESC/POS y ese sigue
// siendo el default. La excepción que motivó esto: la línea TSP100 de Star
// (TSP143 / TSP100II / TSP100III, familia futurePRNT) usa emulación
// StarGraphic — solo acepta gráficos raster. Con ESC/POS acepta los bytes y
// no imprime nada, sin devolver error.
//
// Detección, en orden:
//   1. Override explícito en `printers.connection_config.emulation`
//      ('escpos' | 'star_raster'). Es la salida de emergencia si aparece un
//      modelo que la heurística clasifica mal.
//   2. Vendor ID USB 0x0519 = Star Micronics.
//   3. El nombre con que se dio de alta ("Star TSP143III", "TSP100").
//
// Todo lo demás: ESC/POS.

import '../../../data/models/printing.dart';

enum PrinterEmulation {
  escPos,
  starRaster;

  bool get isStarRaster => this == PrinterEmulation.starRaster;
}

/// Vendor ID USB de Star Micronics.
const int kStarMicronicsVendorId = 0x0519;

PrinterEmulation resolvePrinterEmulation(PrinterConfig printer) {
  final override = printer.connectionConfig['emulation']
      ?.toString()
      .trim()
      .toLowerCase();
  if (override == 'star_raster' || override == 'star' || override == 'raster') {
    return PrinterEmulation.starRaster;
  }
  if (override == 'escpos' || override == 'esc_pos') {
    return PrinterEmulation.escPos;
  }

  final vendorId = _vendorIdOf(printer);
  if (vendorId == kStarMicronicsVendorId) return PrinterEmulation.starRaster;

  final name = printer.name.toLowerCase();
  final looksLikeTsp100 =
      name.contains('tsp10') || // TSP100, TSP100II, TSP100III
      name.contains('tsp14') || // TSP143 (nombre comercial del TSP100III)
      (name.contains('star') && name.contains('tsp'));
  if (looksLikeTsp100) return PrinterEmulation.starRaster;

  return PrinterEmulation.escPos;
}

/// El alta por USB guarda `vendorId:productId` en decimal tanto en
/// `device_path` como en `mac` (ver `PrintersViewModel.scanUSB`). Aceptamos
/// además hex con `0x` y el formato `usb://vid:pid/serie`.
int? _vendorIdOf(PrinterConfig printer) {
  for (final raw in [printer.devicePath, printer.mac]) {
    final parsed = _parseVendorId(raw);
    if (parsed != null) return parsed;
  }
  return null;
}

int? _parseVendorId(String? raw) {
  var s = raw?.trim();
  if (s == null || s.isEmpty) return null;
  if (s.contains('://')) s = s.split('://').last;
  s = s.split('/').first;
  final parts = s.split(':');
  if (parts.isEmpty) return null;
  final head = parts.first.trim();
  if (head.isEmpty) return null;
  if (head.toLowerCase().startsWith('0x')) {
    return int.tryParse(head.substring(2), radix: 16);
  }
  // Sin prefijo el alta lo guarda en decimal.
  return int.tryParse(head);
}
