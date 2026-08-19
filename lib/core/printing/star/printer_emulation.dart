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

/// ¿Esta impresora ESC/POS debe recibir el ticket como IMAGEN en vez de texto?
///
/// Es el "modo calidad": en vez de mandar texto para que lo dibuje la fuente
/// de matriz de puntos del firmware, se rasteriza con tipografía real y se
/// manda con `GS v 0`. Es lo que hace Square, y la única forma de igualar su
/// acabado — ningún ajuste de layout suple la fuente interna.
///
/// OPT-IN por impresora (`printers.connection_config.render = 'raster'`) y
/// no por negocio, porque el coste depende del transporte: un ticket en texto
/// son ~2 KB y en raster 40–150 KB. Por USB o red no se nota; por Bluetooth
/// SPP son varios segundos de espera con el cliente delante.
///
/// No aplica a las Star: esas YA van en raster obligatoriamente porque no
/// hablan ESC/POS (ver [resolvePrinterEmulation]).
bool printerWantsEscPosRaster(PrinterConfig printer) {
  if (resolvePrinterEmulation(printer).isStarRaster) return false;
  final mode = _renderMode(printer);
  return mode == 'raster' || mode == 'image' || mode == 'grafico';
}

/// ¿Este ticket se dibuja con TIPOGRAFÍA REAL (proporcional) o con la rejilla
/// de celdas fijas?
///
/// Las dos salen como imagen; lo que cambia es el acabado. La rejilla imita al
/// firmware — un carácter por celda de 12 puntos — y es lo correcto para las
/// tablas de comandas y cierres, donde las columnas tienen que cuadrar al
/// punto. La proporcional es la de un recibo de Square: ancho variable,
/// negrita de verdad y reglas finas.
///
/// Lo pide el TICKET ([ticketPrefersRaster], hoy el modelo de factura moderno
/// vía `PrintTicket.preferRaster`) o el ajuste de la impresora. Vale también
/// para las Star: que no hablen ESC/POS no las obliga a la rejilla, y a 203
/// dpi dibujan igual de bien un bitmap con tipografía real.
///
/// VÁLVULA DE ESCAPE: `connection_config.render = 'grid'` la fuerza a celdas
/// fijas. Si en una impresora concreta la proporcional sale peor (papel malo,
/// cabezal gastado), se vuelve atrás cambiando una fila en la base de datos y
/// sin build nuevo.
bool wantsProportionalRaster(
  PrinterConfig printer, {
  required bool ticketPrefersRaster,
}) {
  if (printerForcesGridRaster(printer)) return false;
  return ticketPrefersRaster || printerWantsEscPosRaster(printer);
}

/// La impresora pide expresamente la rejilla de celdas fijas
/// (`connection_config.render = 'grid'`). Ver [wantsProportionalRaster].
bool printerForcesGridRaster(PrinterConfig printer) {
  final mode = _renderMode(printer);
  return mode == 'grid' || mode == 'celdas' || mode == 'mono';
}

/// `connection_config.render` normalizado, o null si no está.
String? _renderMode(PrinterConfig printer) =>
    printer.connectionConfig['render']?.toString().trim().toLowerCase();
