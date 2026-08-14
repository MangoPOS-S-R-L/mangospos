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
  static bool looksLikeEscPosRaster(List<int> data) {
    for (var i = 0; i + 2 < data.length && i < 64; i++) {
      if (data[i] == _gs && data[i + 1] == 0x76 && data[i + 2] == 0x30) {
        return true;
      }
    }
    return false;
  }

  /// Convierte el lienzo en el flujo de bytes que se manda a la impresora.
  ///
  /// [openCashDrawer] va DESPUÉS del corte, igual que en el camino de texto:
  /// así el cajero saca el recibo y la gaveta se abre a la vez.
  static List<int> encode(
    MonoBitmap bitmap, {
    bool cut = true,
    bool openCashDrawer = false,
  }) {
    final out = <int>[];
    out.addAll([_esc, 0x40]); // ESC @ — inicializar

    final rows = bitmap.rows;
    final bytesPerRow = bitmap.bytesPerRow;

    for (var start = 0; start < rows.length; start += _bandRows) {
      final end = (start + _bandRows < rows.length)
          ? start + _bandRows
          : rows.length;
      final bandHeight = end - start;

      out.addAll([
        _gs, 0x76, 0x30, 0x00, // GS v 0 m=0
        bytesPerRow & 0xFF, (bytesPerRow >> 8) & 0xFF,
        bandHeight & 0xFF, (bandHeight >> 8) & 0xFF,
      ]);
      for (var y = start; y < end; y++) {
        out.addAll(rows[y]);
      }
    }

    if (cut) {
      // El avance se hace con `ESC J n` (avance en PUNTOS, no en líneas):
      // después de un raster no hay interlineado de texto vigente del que
      // fiarse, y `ESC J` es exacto. Máximo 255 puntos por comando.
      var remaining = feedDotsBeforeCut;
      while (remaining > 0) {
        final step = remaining > 255 ? 255 : remaining;
        out.addAll([_esc, 0x4A, step]); // ESC J n
        remaining -= step;
      }
      out.addAll([_gs, 0x56, 0x00]); // GS V 0 — corte total
    }

    if (openCashDrawer) {
      out.addAll([_esc, 0x70, 0x00, 0x19, 0xFA]); // ESC p
    }

    return out;
  }
}
