// Convierte una imagen a bytes ESC/POS `GS v 0`, alineada, SIN pasar por
// esc_pos_utils_plus.
//
// POR QUE EXISTE (la historia de la "M" fantasma)
//
// El logo y el QR se generaban con `Generator.image()` del paquete
// esc_pos_utils_plus. Ese metodo antepone su propio `setStyles()`, que emite
// comandos que nuestro `EscPosParser` no conoce — entre ellos `FS .`
// (0x1C 0x2E, "salir de modo Kanji"). El parser dejaba pasar esos bytes como
// texto: el 0x1C se dibujaba como el glifo de "caracter desconocido" (un
// cuadrito que en papel termico parece una M) y el punto salia al lado.
// Por eso cada ticket rasterizado amanecia con una "M." pegada al logo y
// otra al QR. Y como esos bytes ademas desincronizaban al parser, el
// `ESC a 1` del centrado podia perderse y el QR salia pegado a la izquierda.
//
// La leccion: si nosotros parseamos el stream, nosotros lo generamos. Este
// helper emite exactamente tres cosas — `ESC a n`, `GS v 0` y `ESC a 0` —
// que son las tres que el parser y las impresoras entienden sin ambiguedad.
//
// El formato `GS v 0 m xL xH yL yH d1..dk`: 1 bit por punto, MSB = punto de
// mas a la izquierda, 1 = tinta. Identico a como `MonoBitmap` guarda filas.

import 'package:image/image.dart' as img;

class RasterImageEscPos {
  RasterImageEscPos._();

  static const int _esc = 0x1B;
  static const int _gs = 0x1D;

  /// Umbral de luminancia: por debajo es tinta. 128 parte el rango al medio,
  /// igual que hacia el paquete que reemplazamos — el acabado no cambia.
  static const int _threshold = 128;

  /// Bytes `GS v 0` de [image], envueltos en alineacion.
  ///
  /// [align]: 0 = izquierda, 1 = centro, 2 = derecha. Siempre se emite
  /// `ESC a 0` al final para no dejar la alineacion cambiada al resto del
  /// ticket — era facil de olvidar y dejaba tickets enteros centrados.
  ///
  /// Los pixeles transparentes cuentan como papel (blanco): los logos PNG
  /// suelen traer fondo transparente y umbralizarlos sin mirar el alfa los
  /// convertia en un bloque negro.
  static List<int> encode(img.Image image, {int align = 1}) {
    final width = image.width;
    final height = image.height;
    final bytesPerRow = (width + 7) ~/ 8;

    final out = <int>[
      _esc, 0x61, align, // ESC a n
      _gs, 0x76, 0x30, 0x00, // GS v 0 m=0
      bytesPerRow & 0xFF, (bytesPerRow >> 8) & 0xFF,
      height & 0xFF, (height >> 8) & 0xFF,
    ];

    for (var y = 0; y < height; y++) {
      for (var bx = 0; bx < bytesPerRow; bx++) {
        var byte = 0;
        for (var bit = 0; bit < 8; bit++) {
          final x = bx * 8 + bit;
          if (x >= width) break;
          final p = image.getPixel(x, y);
          if (p.a < 128) continue; // transparente = papel
          final lum = (p.r * 30 + p.g * 59 + p.b * 11) ~/ 100;
          if (lum < _threshold) byte |= 0x80 >> bit;
        }
        out.add(byte);
      }
    }

    out.addAll([_esc, 0x61, 0x00]); // ESC a 0 — restaurar izquierda
    return out;
  }
}
