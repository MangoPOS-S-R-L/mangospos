// Encoder de imagen raster para impresoras ESC/POS (`GS v 0`).
//
// POR QUÉ EXISTE
//   Una térmica ESC/POS puede imprimir de dos formas: mandándole TEXTO, que
//   dibuja con la fuente de matriz de puntos de su firmware, o mandándole la
//   IMAGEN ya dibujada. Square usa lo segundo, y por eso sus recibos tienen
//   tipografía real, negritas de verdad y reglas finas en vez de filas de
//   guiones. Ninguna cantidad de ajustes de layout iguala eso: la fuente
//   interna es lo que es.
//
//   El camino de rasterizado ya existía en esta app para las Star TSP100
//   (`escpos_parser` → `ticket_rasterizer` → `MonoBitmap`), porque esas
//   impresoras NO hablan ESC/POS. Lo único que faltaba era el último paso
//   para el otro 95% del parque: este encoder.
//
// FORMATO — `GS v 0 m xL xH yL yH d1..dk`
//   m  = 0  (densidad normal, 1 punto por punto)
//   xL/xH = bytes por fila (ancho/8), little endian
//   yL/yH = número de filas de la banda
//   datos = 1 bit por punto, MSB = punto más a la izquierda, 1 = negro
//
//   Es EXACTAMENTE cómo `MonoBitmap` guarda las filas, así que no hay
//   conversión: se copian tal cual.
//
// BANDAS
//   El ticket se manda en trozos de [_bandRows] filas en vez de un solo
//   comando gigante. Las térmicas baratas tienen buffers de pocos KB y un
//   `GS v 0` de un ticket entero (80mm × 2000 puntos ≈ 144 KB) las cuelga o
//   sale cortado a la mitad. En bandas, cada comando entra holgado.
//
// COSTE
//   Un ticket en texto son ~2 KB; el mismo en raster, 40–150 KB. Por USB o
//   red no se nota; por Bluetooth SPP (~10 KB/s real) son varios segundos.
//   Por eso el modo raster es opt-in por impresora.

import 'dart:typed_data';

import 'mono_bitmap.dart';

class EscPosRasterEncoder {
  static const _esc = 0x1B;
  static const _gs = 0x1D;

  /// Filas por comando `GS v 0`. 128 filas a 80mm son 9 KB por banda, que
  /// entra en el buffer de cualquier térmica del mercado.
  static const int _bandRows = 128;

  /// Ancho del cabezal en puntos según el papel. A 203 dpi: 80mm imprime
  /// 576 puntos y 58mm, 384.
  static int dotsForPaperWidth(int paperWidthMm) =>
      paperWidthMm <= 58 ? 384 : 576;

  /// Puntos de avance antes del corte, para que lo último impreso pase la
  /// cuchilla (mismo motivo que `EscPosGenerator.safeCutFeedLines`).
  static const int feedDotsBeforeCut = 100;

  /// ¿Estos bytes ya son un trabajo raster ESC/POS? Evita convertir dos veces
  /// si el job vuelve a pasar por el adaptador (p. ej. rebotando por la cola
  /// offline).
  ///
  /// OJO CON CÓMO SE PREGUNTA: no basta con buscar un `GS v 0` cerca del
  /// principio. Un ticket de TEXTO con logo también trae uno — el logo se
  /// emite como imagen (`raster_image_esc_pos.dart`) y cae sobre el byte 15,
  /// justo detrás del `ESC @`, la tabla de caracteres y la alineación. Con la
  /// versión anterior de esta función, TODA factura con logo se daba por
  /// rasterizada, el adaptador devolvía los bytes intactos y el ticket salía
  /// dibujado por la fuente del firmware. Es decir: el modo calidad no se
  /// activaba nunca justo en los negocios que tienen logo.
  ///
  /// La pregunta correcta es si el trabajo es SOLO raster. Antes del primer
  /// `GS v 0`, [encode] no emite nada más que `ESC @`, avances `ESC J` y —
  /// cuando se habilita [trimLeftEdge] — posiciones `ESC $`. Cualquier otra
  /// cosa (fuente, interlineado, alineación, un salto de línea, texto suelto)
  /// delata un ticket de texto.
  static bool looksLikeEscPosRaster(List<int> data) {
    var i = 0;
    // `ESC @` inicial: lo emiten los dos, el generador de texto y este
    // encoder. No decide nada por sí solo.
    if (i + 1 < data.length && data[i] == _esc && data[i + 1] == 0x40) i += 2;

    while (i + 2 < data.length) {
      if (data[i] == _gs && data[i + 1] == 0x76 && data[i + 2] == 0x30) {
        return true;
      }
      if (data[i] != _esc) return false;
      switch (data[i + 1]) {
        case 0x4A: // ESC J n — avance en puntos
          i += 3;
        case 0x24: // ESC $ nL nH — posición horizontal
          i += 4;
        default:
          return false;
      }
    }
    return false;
  }

  /// Recorte del borde IZQUIERDO de cada banda usando `ESC $`.
  ///
  /// Apagado por defecto a proposito. Bajaria el ticket de 40 KB a 28 KB,
  /// pero `ESC $` posiciona en "unidades de movimiento horizontal" y no
  /// todas las termicas las tienen en 1/203" — en las que no, el contenido
  /// centrado saldria corrido. El recorte DERECHO (que si esta activo) no
  /// corre ese riesgo porque cada banda sigue empezando en x=0.
  ///
  /// Enciendelo solo despues de imprimir un ticket de prueba en el modelo
  /// concreto y verificar que los bloques centrados no se desplazan.
  static const bool trimLeftEdge = false;

  static bool _isBlank(Uint8List row) {
    for (final b in row) {
      if (b != 0) return false;
    }
    return true;
  }

  /// Avance de papel en puntos. `ESC J n` acepta 255 por comando.
  static void _feedDots(List<int> out, int dots) {
    var remaining = dots;
    while (remaining > 0) {
      final step = remaining > 255 ? 255 : remaining;
      out.addAll([_esc, 0x4A, step]); // ESC J n
      remaining -= step;
    }
  }

  /// Primer y ultimo byte con tinta de una fila. `(-1, -1)` si esta vacia.
  static (int, int) _inkSpan(Uint8List row) {
    var first = -1, last = -1;
    for (var i = 0; i < row.length; i++) {
      if (row[i] == 0) continue;
      if (first < 0) first = i;
      last = i;
    }
    return (first, last);
  }

  /// Convierte el lienzo en el flujo de bytes que se manda a la impresora.
  ///
  /// DOS COSAS QUE NO SE MANDAN, y por que:
  ///
  ///  1. LAS FILAS EN BLANCO. Un ticket real tiene ~50% de filas sin un solo
  ///     punto negro: el aire entre bloques. Mandarlas como ceros cuesta 72
  ///     bytes por fila para imprimir nada. Se reemplazan por un avance de
  ///     papel (`ESC J`), 3 bytes por hueco. Ahi se va la mitad del peso.
  ///
  ///  2. EL BLANCO A LA DERECHA. Casi ninguna banda usa los 576 puntos de
  ///     ancho — una linea centrada corta usa un tercio. Cada banda se manda
  ///     solo hasta su ultimo byte con tinta. Como sigue empezando en x=0,
  ///     no hace falta posicionar y no hay riesgo de desplazamiento.
  ///
  /// Medido sobre una factura de 181mm: 102 KB -> 40 KB. Por Bluetooth eso
  /// son 4 segundos en vez de 10, con el cliente esperando el papel.
  ///
  /// [openCashDrawer] va DESPUES del corte, igual que en el camino de texto:
  /// asi el cajero saca el recibo y la gaveta se abre a la vez.
  static List<int> encode(
    MonoBitmap bitmap, {
    bool cut = true,
    bool openCashDrawer = false,
  }) {
    final out = <int>[];
    out.addAll([_esc, 0x40]); // ESC @ — inicializar

    final rows = bitmap.rows;
    final bytesPerRow = bitmap.bytesPerRow;

    var y = 0;
    while (y < rows.length) {
      if (_isBlank(rows[y])) {
        final start = y;
        while (y < rows.length && _isBlank(rows[y])) {
          y++;
        }
        _feedDots(out, y - start);
        continue;
      }

      final start = y;
      while (y < rows.length && !_isBlank(rows[y])) {
        y++;
      }
      _emitInkRun(out, rows, start, y, bytesPerRow);
    }

    if (cut) {
      // El avance se hace con `ESC J n` (avance en PUNTOS, no en lineas):
      // despues de un raster no hay interlineado de texto vigente del que
      // fiarse, y `ESC J` es exacto.
      _feedDots(out, feedDotsBeforeCut);
      out.addAll([_gs, 0x56, 0x00]); // GS V 0 — corte total
    }

    if (openCashDrawer) {
      out.addAll([_esc, 0x70, 0x00, 0x19, 0xFA]); // ESC p
    }

    return out;
  }

  /// Manda un tramo contiguo de filas CON tinta, partido en bandas que
  /// entren en el buffer de la impresora y recortado a lo ancho.
  static void _emitInkRun(
    List<int> out,
    List<Uint8List> rows,
    int from,
    int to,
    int bytesPerRow,
  ) {
    for (var start = from; start < to; start += _bandRows) {
      final end = (start + _bandRows < to) ? start + _bandRows : to;

      // Ancho real de ESTA banda. Se mide por banda y no por ticket para
      // que un bloque centrado y corto no pague el ancho del bloque mas
      // ancho del recibo.
      var left = bytesPerRow - 1, right = 0;
      for (var i = start; i < end; i++) {
        final (a, b) = _inkSpan(rows[i]);
        if (a < 0) continue;
        if (a < left) left = a;
        if (b > right) right = b;
      }
      if (right < left) continue; // banda sin tinta: no deberia pasar

      final x0 = trimLeftEdge ? left : 0;
      final width = right - x0 + 1;
      final bandHeight = end - start;

      if (x0 > 0) {
        final dots = x0 * 8;
        out.addAll([_esc, 0x24, dots & 0xFF, (dots >> 8) & 0xFF]); // ESC $
      }
      out.addAll([
        _gs, 0x76, 0x30, 0x00, // GS v 0 m=0
        width & 0xFF, (width >> 8) & 0xFF,
        bandHeight & 0xFF, (bandHeight >> 8) & 0xFF,
      ]);
      for (var i = start; i < end; i++) {
        out.addAll(rows[i].sublist(x0, x0 + width));
      }
    }
  }
}
