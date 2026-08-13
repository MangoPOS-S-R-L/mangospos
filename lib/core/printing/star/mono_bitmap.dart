// Lienzo monocromo de 1 bit por punto, empaquetado igual que lo espera el
// modo raster de Star: filas de `width / 8` bytes, MSB = punto más a la
// izquierda, bit en 1 = punto negro.
//
// Se guarda ya empaquetado (y no como lista de bool) porque es exactamente
// el formato que el encoder manda por el cable: cero conversión al final, y
// un ticket de 80mm × 2000 puntos ocupa 144 KB en vez de 1.1 MB.

import 'dart:typed_data';

class MonoBitmap {
  MonoBitmap(this.width) : bytesPerRow = (width + 7) ~/ 8;

  /// Ancho en puntos (576 en 80mm, 384 en 58mm).
  final int width;
  final int bytesPerRow;

  final List<Uint8List> _rows = [];

  int get height => _rows.length;
  List<Uint8List> get rows => List.unmodifiable(_rows);

  /// Agrega filas en blanco hasta llegar a [target] de alto.
  void ensureHeight(int target) {
    while (_rows.length < target) {
      _rows.add(Uint8List(bytesPerRow));
    }
  }

  void setPixel(int x, int y, {bool on = true}) {
    if (x < 0 || x >= width || y < 0) return;
    ensureHeight(y + 1);
    final row = _rows[y];
    final mask = 0x80 >> (x % 8);
    if (on) {
      row[x ~/ 8] |= mask;
    } else {
      row[x ~/ 8] &= ~mask & 0xFF;
    }
  }

  /// Copia un bloque de píxeles (`pixels[y * w + x]`, true = negro) con su
  /// esquina superior izquierda en ([dx], [dy]). Lo que se salga por los
  /// lados se recorta; hacia abajo el lienzo crece solo.
  void blit(List<bool> pixels, int w, int h, int dx, int dy) {
    ensureHeight(dy + h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (!pixels[y * w + x]) continue;
        setPixel(dx + x, dy + y);
      }
    }
  }

  /// Recorta las filas totalmente en blanco del final. El avance previo al
  /// corte lo pone el encoder, no el contenido.
  void trimTrailingBlankRows() {
    while (_rows.isNotEmpty && _rows.last.every((b) => b == 0)) {
      _rows.removeLast();
    }
  }
}
