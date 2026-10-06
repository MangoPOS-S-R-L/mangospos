// Ancho del ticket en COLUMNAS, por impresora.
//
// EL PROBLEMA QUE RESUELVE
//   El raster (factura y precuenta "Moderna", Star TSP100) se compone a 48
//   columnas de 12 puntos en 80mm — 576 puntos, el cabezal de una térmica de
//   203 dpi — y a 32 en 58mm. Pero no todas lo son. Las Epson TM-T88 y sus
//   clones van a 180 dpi y su cabezal de 80mm mide 512 puntos; otras traen el
//   área de impresión configurada a 64mm.
//
//   En esas impresoras la imagen de 576 puntos no cabe y la térmica tira lo
//   que sobra por la derecha: se cortan los montos ("RD$" sin la cifra,
//   "RD$45." sin los centavos) y, como cada punto mide 0.141mm en vez de
//   0.125mm, toda la letra sale ~13% más grande que en el resto del parque.
//   Caso que lo motivó (2026-10-06): una precuenta Moderna con la letra
//   "grande" y los importes cortados a la derecha.
//
// LA SOLUCIÓN
//   El dueño elige a mano cuántas columnas quiere (p. ej. 42 en vez de 48) y
//   el ticket sale con EL MISMO diseño, más angosto: se sigue componiendo a
//   48 —la rejilla con la que lo armó el builder— y el rasterizador lo dibuja
//   escalado a `columnas × 12` puntos. No es achicar el bitmap ya hecho (eso
//   rompe los trazos de 1 bit): la tipografía se dibuja ya a la escala final
//   y se binariza después. La letra baja en la misma proporción que el ancho.
//
//   Un ticket más angosto que el papel sale CENTRADO: en ESC/POS con
//   `ESC a 1`, que la impresora aplica dentro de su propio ancho —el mismo
//   mecanismo con que ya se centran el logo y el QR—, así que no hace falta
//   saber cuánto mide el cabezal. En Star (raster propio, sin alineación) se
//   rellena a los lados.
//
// Solo afecta a lo que sale como IMAGEN. Lo que imprime la fuente del
// firmware (modelo Estándar, comandas) sigue en las columnas de siempre.

import '../../../data/models/printing.dart';

/// Clave dentro de `printers.connection_config`. El default no se guarda:
/// una impresora sin la clave imprime como todas las demás.
const String kPrintColumnsConfigKey = 'print_columns';

/// Puntos por columna: la celda de la fuente A (576/48 = 384/32 = 12).
const int kDotsPerColumn = 12;

/// Columnas con las que el builder COMPONE el ticket: 48 en 80mm, 32 en
/// 58mm. Es también el máximo: más ancho que eso no cabe en el papel.
int defaultColumnsForPaperWidth(int paperWidthMm) =>
    paperWidthMm <= 58 ? 32 : 48;

/// Mínimo que se deja elegir. Por debajo, la letra queda tan chica que el
/// ticket deja de leerse a un brazo de distancia.
int minColumnsForPaperWidth(int paperWidthMm) =>
    paperWidthMm <= 58 ? 24 : 32;

/// Ancho de la rejilla del layout en puntos (576 en 80mm, 384 en 58mm).
int layoutDotsForPaperWidth(int paperWidthMm) =>
    defaultColumnsForPaperWidth(paperWidthMm) * kDotsPerColumn;

/// [columns] acotado al rango que admite un papel de [paperWidthMm].
int clampColumns(int columns, int paperWidthMm) {
  final max = defaultColumnsForPaperWidth(paperWidthMm);
  final min = minColumnsForPaperWidth(paperWidthMm);
  if (columns > max) return max;
  if (columns < min) return min;
  return columns;
}

/// Lo que se guarda en `connection_config` para [columns]: null si es el
/// default del papel (y entonces se borra la clave).
int? printColumnsWireValue(int columns, int paperWidthMm) {
  final value = clampColumns(columns, paperWidthMm);
  return value == defaultColumnsForPaperWidth(paperWidthMm) ? null : value;
}

/// Columnas elegidas para [printer], ya acotadas a su papel. Un valor
/// guardado raro (texto, fuera de rango) no rompe: cae en el rango o en el
/// default.
int resolvePrintColumns(PrinterConfig printer) {
  final raw = printer.connectionConfig[kPrintColumnsConfigKey];
  final parsed = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}'.trim());
  if (parsed == null) return defaultColumnsForPaperWidth(printer.paperWidth);
  return clampColumns(parsed, printer.paperWidth);
}

/// Ancho en puntos de la imagen que se manda a [printer].
int resolvePrintDots(PrinterConfig printer) =>
    resolvePrintColumns(printer) * kDotsPerColumn;
