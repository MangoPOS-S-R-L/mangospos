// Encoder del modo raster de Star (StarGraphic / futurePRNT).
//
// Es el "idioma" que sí entiende la línea TSP100 (TSP143 / TSP100II /
// TSP100III): en vez de texto con atributos, se le manda el ticket ya
// dibujado, fila de puntos por fila de puntos.
//
// Secuencia que emitimos:
//
//   1B 40              ESC @        inicializar
//   1B 2A 72 41        ESC * r A    entrar a modo raster
//   1B 2A 72 50 30 00  ESC * r P 0  longitud de página = continua
//   62 n1 n2 <datos>   b            una fila de puntos (n1n2 = bytes, LSB first)
//   ...
//   1B 0C 00           ESC FF NUL   imprimir y avanzar a la posición de corte
//   1B 2A 72 42        ESC * r B    salir de modo raster
//   1B 64 33           ESC d 3      corte parcial con avance (si el ticket lo pedía)
//
// Las filas en blanco se mandan como filas de ceros en vez de usar el avance
// por puntos: son más bytes pero una sola ruta de código, y el cuello de
// botella real es el cabezal, no el USB.

import 'mono_bitmap.dart';

class StarRasterEncoder {
  static const _esc = 0x1B;

  /// Ancho del cabezal en puntos según el papel. A 203 dpi: 80mm imprime
  /// 576 puntos y 58mm, 384.
  static int dotsForPaperWidth(int paperWidthMm) =>
      paperWidthMm <= 58 ? 384 : 576;

  /// Puntos de avance antes del corte, para que lo último impreso pase la
  /// cuchilla (mismo motivo que `EscPosGenerator.safeCutFeedLines`).
  static const int feedDotsBeforeCut = 100;

  /// ¿Estos bytes ya son un trabajo raster de Star? Evita convertir dos veces
  /// si el job vuelve a pasar por el adaptador.
  static bool looksLikeStarRaster(List<int> data) {
    for (var i = 0; i + 3 < data.length && i < 32; i++) {
      if (data[i] == _esc &&
          data[i + 1] == 0x2A &&
          data[i + 2] == 0x72 &&
          data[i + 3] == 0x41) {
        return true;
      }
    }
    return false;
  }

  /// Convierte el lienzo en el flujo de bytes que se manda a la impresora.
  static List<int> encode(MonoBitmap bitmap, {bool cut = true}) {
    final out = <int>[];

    out.addAll([_esc, 0x40]); // ESC @
    out.addAll([_esc, 0x2A, 0x72, 0x41]); // ESC * r A
    out.addAll([_esc, 0x2A, 0x72, 0x50, 0x30, 0x00]); // ESC * r P 0 NUL

    for (final row in bitmap.rows) {
      out.add(0x62); // 'b' — datos de una fila
      out.add(row.length & 0xFF);
      out.add((row.length >> 8) & 0xFF);
      out.addAll(row);
    }

    // Avance previo al corte, en filas vacías del mismo ancho.
    if (cut && feedDotsBeforeCut > 0) {
      final blank = List<int>.filled(bitmap.bytesPerRow, 0);
      for (var i = 0; i < feedDotsBeforeCut; i++) {
        out.add(0x62);
        out.add(blank.length & 0xFF);
        out.add((blank.length >> 8) & 0xFF);
        out.addAll(blank);
      }
    }

    out.addAll([_esc, 0x0C, 0x00]); // ESC FF NUL — imprimir página
    out.addAll([_esc, 0x2A, 0x72, 0x42]); // ESC * r B — salir de raster
    if (cut) {
      out.addAll([_esc, 0x64, 0x33]); // ESC d 3 — corte parcial
    }
    return out;
  }
}
