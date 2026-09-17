// Velocidad de impresión por impresora.
//
// Una térmica imprime más nítido cuanto más despacio avanza: el cabezal
// tiene más tiempo para calentar cada punto y el papel no "arrastra" las
// líneas finas (logo, QR, letra pequeña). La velocidad es la palanca de
// CALIDAD que exponen los firmwares; la densidad (GS ( K fn 49) casi ningún
// modelo la soporta.
//
// Se guarda en `printers.connection_config.print_speed`:
//   'fast' | 'normal' | 'slow'. Ausente = no se manda NADA y la impresora
//   usa su propio ajuste — el comportamiento de siempre.
//
// Comandos (verificados contra la referencia oficial de cada fabricante):
//
//   ESC/POS (Epson y compatibles) — GS ( K <Function 50>:
//     1D 28 4B 02 00 32 m      m = 1 (la más lenta) … 9
//     1–9 es el rango que aceptan TODOS los modelos TM; algunos llegan a
//     13–17, pero 9 no deja a ninguno fuera. El ajuste se borra con ESC @,
//     así que va justo DESPUÉS del ESC @ con que arranca cada ticket.
//
//   Star modo raster (TSP100) — ESC * r Q n NUL:
//     1B 2A 72 51 n 00         n en ASCII: '0' alta velocidad, '1' normal,
//                              '2' alta calidad. Va después de ESC * r A.
//
// Las impresoras que no conocen el comando lo descartan: `GS (` lleva su
// longitud (pL pH), así que el firmware sabe cuántos bytes saltar.

import '../../../data/models/printing.dart';

enum PrintSpeed {
  /// No se manda comando: manda la configuración de la impresora.
  printerDefault,
  fast,
  normal,
  slow;

  /// Valor guardado en `connection_config.print_speed`. Null = sin ajuste.
  String? get wireValue => switch (this) {
    PrintSpeed.printerDefault => null,
    PrintSpeed.fast => 'fast',
    PrintSpeed.normal => 'normal',
    PrintSpeed.slow => 'slow',
  };

  static PrintSpeed fromWire(Object? raw) {
    return switch (raw?.toString().trim().toLowerCase()) {
      'fast' || 'rapida' || 'rápida' => PrintSpeed.fast,
      'normal' || 'media' => PrintSpeed.normal,
      'slow' || 'lenta' || 'quality' || 'calidad' => PrintSpeed.slow,
      _ => PrintSpeed.printerDefault,
    };
  }
}

/// Clave dentro de `printers.connection_config`.
const String kPrintSpeedConfigKey = 'print_speed';

PrintSpeed resolvePrintSpeed(PrinterConfig printer) =>
    PrintSpeed.fromWire(printer.connectionConfig[kPrintSpeedConfigKey]);

const int _esc = 0x1B;
const int _gs = 0x1D;

/// Nivel de `GS ( K <Function 50>` para cada velocidad.
int? _epsonSpeedLevel(PrintSpeed speed) => switch (speed) {
  PrintSpeed.printerDefault => null,
  PrintSpeed.fast => 9,
  PrintSpeed.normal => 5,
  PrintSpeed.slow => 1,
};

/// Parámetro ASCII de `ESC * r Q` para cada velocidad.
int? _starQualityDigit(PrintSpeed speed) => switch (speed) {
  PrintSpeed.printerDefault => null,
  PrintSpeed.fast => 0x30, // '0' alta velocidad
  PrintSpeed.normal => 0x31, // '1' normal
  PrintSpeed.slow => 0x32, // '2' alta calidad
};

/// Devuelve [data] con el comando de velocidad insertado donde el firmware
/// lo respeta. Es idempotente: el adaptador puede correr dos veces sobre el
/// mismo trabajo (p.ej. `printEscPos` → `printRawDirectUsb`) y no se duplica.
///
/// Solo toca TICKETS: bytes que arrancan con `ESC @` (ESC/POS) o que traen
/// `ESC * r A` (raster Star). Un pulso suelto de gaveta o cualquier otro
/// fragmento crudo sale intacto.
List<int> applyPrintSpeed(List<int> data, PrintSpeed speed) {
  if (speed == PrintSpeed.printerDefault || data.length < 2) return data;

  final starRasterAt = _indexOfStarEnterRaster(data);
  if (starRasterAt != null) {
    final insertAt = starRasterAt + 4;
    if (_hasStarQualityAt(data, insertAt)) return data;
    return [
      ...data.sublist(0, insertAt),
      _esc, 0x2A, 0x72, 0x51, _starQualityDigit(speed)!, 0x00,
      ...data.sublist(insertAt),
    ];
  }

  if (data[0] != _esc || data[1] != 0x40) return data;
  if (_hasEpsonSpeedAt(data, 2)) return data;
  return [
    _esc, 0x40, // ESC @
    _gs, 0x28, 0x4B, 0x02, 0x00, 0x32, _epsonSpeedLevel(speed)!,
    ...data.sublist(2),
  ];
}

/// Posición de `ESC * r A` dentro de la cabecera (mismo alcance que
/// `StarRasterEncoder.looksLikeStarRaster`).
int? _indexOfStarEnterRaster(List<int> data) {
  for (var i = 0; i + 3 < data.length && i < 32; i++) {
    if (data[i] == _esc &&
        data[i + 1] == 0x2A &&
        data[i + 2] == 0x72 &&
        data[i + 3] == 0x41) {
      return i;
    }
  }
  return null;
}

bool _hasStarQualityAt(List<int> data, int i) =>
    i + 3 < data.length &&
    data[i] == _esc &&
    data[i + 1] == 0x2A &&
    data[i + 2] == 0x72 &&
    data[i + 3] == 0x51;

bool _hasEpsonSpeedAt(List<int> data, int i) =>
    i + 5 < data.length &&
    data[i] == _gs &&
    data[i + 1] == 0x28 &&
    data[i + 2] == 0x4B &&
    data[i + 3] == 0x02 &&
    data[i + 4] == 0x00 &&
    data[i + 5] == 0x32;
