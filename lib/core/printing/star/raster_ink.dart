// Cuánta TINTA pone el raster, por impresora.
//
// EL PROBLEMA QUE RESUELVE
//   El "modo calidad" dibuja el ticket con tipografía real y lo manda como
//   imagen de 1 bit (ver `esc_pos_raster_encoder.dart`). Ese último paso —
//   decidir qué punto es negro y cuál blanco — es donde se pierde el trazo:
//   el glifo viene con bordes antialiaseados en gris y hay que quedarse con
//   sí o no.
//
//   Con el umbral a la mitad exacta (128), los palos de la letra caen unas
//   veces en 2 puntos y otras en 3, según dónde quede el glifo respecto a la
//   rejilla de puntos del cabezal. Medido sobre una línea de factura real a
//   24 puntos: 255 palos de 2 y 265 de 3. Esa mezcla es lo que en papel se
//   lee como "claro y poco nítido" — no es que falte tinta en general, es
//   que el mismo trazo cambia de grosor dentro de la misma palabra.
//
//   Y encima el resultado depende del CABEZAL: la misma imagen sale negra en
//   una térmica y gris en otra. Por eso esto es un ajuste por impresora y no
//   una constante.
//
// LOS TRES NIVELES (medidos sobre la misma línea, 576 puntos de ancho):
//
//   fina       umbral 128 → 2182 puntos de tinta. Es como salía hasta ahora.
//   normal     umbral 176 → 2523 (+16%), y el 90% de los palos queda en 3
//              puntos en vez de repartirse entre 2 y 3. Es el default.
//   reforzada  umbral 176 + engorde de 1 punto → 2830 (+30%). Para los
//              cabezales que aun así sacan la letra gris.
//
//   El umbral crece el trazo por los BORDES (se queda con el gris que antes
//   se tiraba), así que no mueve ni una letra de sitio: el layout, el
//   ajuste de ancho y los cortes de línea son exactamente los mismos.
//   Verificado que a 176 los huecos de la `e` y la `a` siguen abiertos; por
//   eso no se sube más y el escalón siguiente es engordar, no subir umbral.
//
// LO QUE ESTO NO ES: la otra palanca de nitidez, y la primera que hay que
// probar, es la VELOCIDAD (`print_speed.dart`). Una térmica quema mejor cada
// punto cuanto más despacio avanza. Esto de aquí es para cuando la impresora
// ya va lenta y la letra sigue clara.

import '../../../data/models/printing.dart';

enum RasterInk {
  /// Trazo original (umbral 128). Válvula de escape para el cabezal que con
  /// el default emborrona los huecos de las letras.
  fina,

  /// Default: trazo parejo de 3 puntos.
  normal,

  /// Un punto más de engorde, para cabezales que sacan la letra gris.
  reforzada;

  /// Umbral de luminancia: por debajo de esto, el punto es tinta.
  int get threshold => this == RasterInk.fina ? 128 : 176;

  /// Puntos de engorde horizontal del trazo ya binarizado.
  int get dilate => this == RasterInk.reforzada ? 1 : 0;

  /// Valor guardado en `connection_config.raster_ink`. El default no se
  /// guarda: una impresora sin la clave imprime como todas las demás.
  String? get wireValue => switch (this) {
    RasterInk.normal => null,
    RasterInk.fina => 'fina',
    RasterInk.reforzada => 'reforzada',
  };

  static RasterInk fromWire(Object? raw) {
    return switch (raw?.toString().trim().toLowerCase()) {
      'fina' || 'thin' || 'light' => RasterInk.fina,
      'reforzada' || 'bold' || 'dark' || 'heavy' => RasterInk.reforzada,
      _ => RasterInk.normal,
    };
  }
}

/// Clave dentro de `printers.connection_config`.
const String kRasterInkConfigKey = 'raster_ink';

RasterInk resolveRasterInk(PrinterConfig printer) =>
    RasterInk.fromWire(printer.connectionConfig[kRasterInkConfigKey]);
