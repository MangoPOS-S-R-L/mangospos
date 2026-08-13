// Intérprete del subconjunto de ESC/POS que genera MangoPOS.
//
// POR QUÉ EXISTE:
//   Las Star de la línea TSP100 (TSP143/TSP100II/TSP100III, familia
//   futurePRNT) NO hablan ESC/POS: usan emulación StarGraphic, que solo
//   entiende comandos de gráfico raster. Si les mandas ESC/POS, aceptan los
//   bytes en el endpoint y no imprimen nada — sin error.
//
//   En vez de duplicar cada builder de ticket con una variante Star, aquí
//   deshacemos el ESC/POS que YA generamos: lo convertimos en una lista de
//   operaciones (líneas con estilo + imágenes) que el rasterizador dibuja y
//   el encoder Star manda como bitmap. Así factura, comanda, precuenta,
//   cierre y recibo salen en Star sin tocar un solo builder.
//
// ALCANCE:
//   Solo el subconjunto que emite `EscPosGenerator` + las imágenes de
//   `LogoEscPosBuilder` / `QrEscPosBuilder` (que usan `ESC *` vía
//   esc_pos_utils_plus). Cualquier comando desconocido se SALTA sin romper:
//   preferimos un ticket con un detalle de menos a no imprimir nada.
//
// Sin dependencias de Flutter a propósito: esto es lógica pura y testeable.
// El dibujado vive en `ticket_rasterizer.dart`.

import 'dart:convert';
import 'dart:typed_data';

/// Alineación vigente al emitir una línea.
enum TicketAlign { left, center, right }

/// Una línea de texto con el estilo que tenía en el flujo ESC/POS.
class TicketTextOp {
  const TicketTextOp({
    required this.text,
    this.align = TicketAlign.left,
    this.bold = false,
    this.inverse = false,
    this.underline = false,
    this.widthFactor = 1,
    this.heightFactor = 1,
  });

  final String text;
  final TicketAlign align;
  final bool bold;
  final bool inverse;
  final bool underline;

  /// Factores de `GS !` (1 = normal, 2 = doble). Se respetan tal cual: una
  /// línea en 2x ocupa el doble de celda a lo ancho y/o alto.
  final int widthFactor;
  final int heightFactor;

  @override
  String toString() =>
      'TicketTextOp("$text", ${align.name}, b:$bold, i:$inverse, '
      'w:$widthFactor, h:$heightFactor)';
}

/// Un bloque de imagen ya decodificado a píxeles (1 = punto negro).
class TicketImageOp {
  const TicketImageOp({
    required this.width,
    required this.height,
    required this.pixels,
    this.align = TicketAlign.center,
  });

  final int width;
  final int height;

  /// `pixels[y * width + x]`, true = punto negro.
  final List<bool> pixels;
  final TicketAlign align;
}

/// Resultado del parseo: las operaciones en orden + si el ticket pedía corte.
class ParsedTicket {
  const ParsedTicket({required this.ops, required this.cut});

  final List<Object> ops; // TicketTextOp | TicketImageOp
  final bool cut;
}

/// Deshace el ESC/POS de un ticket de MangoPOS.
class EscPosParser {
  static const _esc = 0x1B;
  static const _gs = 0x1D;
  static const _lf = 0x0A;
  static const _cr = 0x0D;

  /// [data] son los bytes tal como saldrían por el puerto de la impresora.
  static ParsedTicket parse(List<int> data) {
    final ops = <Object>[];
    var cut = false;

    var align = TicketAlign.left;
    var bold = false;
    var inverse = false;
    var underline = false;
    var widthFactor = 1;
    var heightFactor = 1;

    // Buffer de la línea en curso. Se vacía en cada LF.
    final line = <int>[];
    // Blobs de `ESC *` consecutivos: cada uno son 24 filas de alto, y se
    // apilan verticalmente para formar el logo/QR completo.
    List<_ImageBlob>? pendingBlobs;

    void flushImage() {
      final blobs = pendingBlobs;
      pendingBlobs = null;
      if (blobs == null || blobs.isEmpty) return;
      ops.add(_mergeBlobs(blobs, align));
    }

    // Cierra la línea SOLO si hay texto pendiente. La usan los comandos que
    // interrumpen una línea sin terminarla (reset, imagen): con `flushLine`
    // metían un renglón en blanco fantasma que corría todo el ticket.
    void flushPending() {
      if (line.isEmpty) return;
      final text = latin1.decode(line, allowInvalid: true);
      line.clear();
      ops.add(
        TicketTextOp(
          text: text,
          align: align,
          bold: bold,
          inverse: inverse,
          underline: underline,
          widthFactor: widthFactor,
          heightFactor: heightFactor,
        ),
      );
    }

    void flushLine() {
      if (line.isEmpty) {
        // LF sin texto = renglón en blanco; lo conservamos porque el layout
        // del ticket depende de esos espacios.
        ops.add(
          TicketTextOp(
            text: '',
            align: align,
            widthFactor: widthFactor,
            heightFactor: heightFactor,
          ),
        );
        return;
      }
      final text = latin1.decode(line, allowInvalid: true);
      line.clear();
      ops.add(
        TicketTextOp(
          text: text,
          align: align,
          bold: bold,
          inverse: inverse,
          underline: underline,
          widthFactor: widthFactor,
          heightFactor: heightFactor,
        ),
      );
    }

    var i = 0;
    while (i < data.length) {
      final b = data[i];

      if (b == _esc && i + 1 < data.length) {
        final cmd = data[i + 1];
        switch (cmd) {
          case 0x40: // ESC @ — reset
            flushPending();
            align = TicketAlign.left;
            bold = false;
            inverse = false;
            underline = false;
            widthFactor = 1;
            heightFactor = 1;
            i += 2;
            continue;
          case 0x61: // ESC a n — alineación
            if (i + 2 >= data.length) return _done(ops, cut);
            flushImage();
            align = switch (data[i + 2]) {
              1 => TicketAlign.center,
              2 => TicketAlign.right,
              _ => TicketAlign.left,
            };
            i += 3;
            continue;
          case 0x45: // ESC E n — negrita
            if (i + 2 >= data.length) return _done(ops, cut);
            bold = data[i + 2] != 0;
            i += 3;
            continue;
          case 0x2D: // ESC - n — subrayado
            if (i + 2 >= data.length) return _done(ops, cut);
            underline = data[i + 2] != 0;
            i += 3;
            continue;
          case 0x74: // ESC t n — code table (irrelevante: decodificamos Latin-1)
          case 0x47: // ESC G n — double strike (el raster ya sale nítido)
          case 0x4D: // ESC M n — fuente A/B
          case 0x33: // ESC 3 n — interlineado
          case 0x64: // ESC d n — avanzar n líneas
            if (i + 2 >= data.length) return _done(ops, cut);
            if (cmd == 0x64) {
              flushLine();
              final n = data[i + 2];
              for (var k = 0; k < n; k++) {
                ops.add(TicketTextOp(text: '', align: align));
              }
            }
            i += 3;
            continue;
          case 0x32: // ESC 2 — interlineado default
            i += 2;
            continue;
          case 0x70: // ESC p m t1 t2 — gaveta (no aplica al papel)
            i += 5;
            continue;
          case 0x2A: // ESC * m nL nH data — bit image (logo / QR)
            if (i + 4 >= data.length) return _done(ops, cut);
            final m = data[i + 2];
            final n = data[i + 3] | (data[i + 4] << 8);
            // m 0/1 = 8 puntos de alto (1 byte por columna); 32/33 = 24 (3).
            final bytesPerCol = (m == 32 || m == 33) ? 3 : 1;
            final len = n * bytesPerCol;
            final start = i + 5;
            final end = start + len;
            if (end > data.length) return _done(ops, cut);
            flushPending();
            (pendingBlobs ??= <_ImageBlob>[]).add(
              _ImageBlob(
                columns: n,
                bytesPerColumn: bytesPerCol,
                data: Uint8List.fromList(data.sublist(start, end)),
              ),
            );
            i = end;
            // El generador cierra cada blob con LF; ese salto es parte del
            // gráfico, no un renglón en blanco.
            if (i < data.length && data[i] == _lf) i++;
            continue;
          default:
            // Desconocido: saltamos ESC + comando y seguimos. Perder un
            // atributo es mejor que abortar el ticket completo.
            i += 2;
            continue;
        }
      }

      if (b == _gs && i + 1 < data.length) {
        final cmd = data[i + 1];
        switch (cmd) {
          case 0x21: // GS ! n — tamaño
            if (i + 2 >= data.length) return _done(ops, cut);
            final n = data[i + 2];
            widthFactor = ((n >> 4) & 0x07) + 1;
            heightFactor = (n & 0x07) + 1;
            i += 3;
            continue;
          case 0x42: // GS B n — inverso
            if (i + 2 >= data.length) return _done(ops, cut);
            inverse = data[i + 2] != 0;
            i += 3;
            continue;
          case 0x56: // GS V — corte (formas: GS V m | GS V B n)
            if (i + 2 >= data.length) return _done(ops, cut);
            cut = true;
            i += (data[i + 2] == 0x42) ? 4 : 3;
            continue;
          case 0x76: // GS v 0 m xL xH yL yH — raster bit image
            if (i + 7 >= data.length) return _done(ops, cut);
            final xBytes = data[i + 4] | (data[i + 5] << 8);
            final yDots = data[i + 6] | (data[i + 7] << 8);
            final start = i + 8;
            final end = start + xBytes * yDots;
            if (end > data.length) return _done(ops, cut);
            flushPending();
            flushImage();
            ops.add(
              _rasterToOp(
                Uint8List.fromList(data.sublist(start, end)),
                xBytes,
                yDots,
                align,
              ),
            );
            i = end;
            continue;
          default:
            i += 2;
            continue;
        }
      }

      if (b == _lf) {
        if (pendingBlobs != null) {
          // LF entre blobs de imagen: ya lo consumimos arriba, pero si llega
          // suelto cerramos el gráfico.
          flushImage();
        } else {
          flushLine();
        }
        i++;
        continue;
      }

      if (b == _cr) {
        i++;
        continue;
      }

      flushImage();
      line.add(b);
      i++;
    }

    flushPending();
    flushImage();
    return ParsedTicket(ops: ops, cut: cut);
  }

  static ParsedTicket _done(List<Object> ops, bool cut) =>
      ParsedTicket(ops: ops, cut: cut);

  /// Apila los blobs de `ESC *` (24 filas cada uno) en una sola imagen.
  static TicketImageOp _mergeBlobs(List<_ImageBlob> blobs, TicketAlign align) {
    final width = blobs.map((b) => b.columns).reduce((a, b) => a > b ? a : b);
    final rowsPerBlob = blobs.first.bytesPerColumn * 8;
    final height = rowsPerBlob * blobs.length;
    final pixels = List<bool>.filled(width * height, false);

    for (var bi = 0; bi < blobs.length; bi++) {
      final blob = blobs[bi];
      final yBase = bi * rowsPerBlob;
      for (var col = 0; col < blob.columns; col++) {
        for (var byteIdx = 0; byteIdx < blob.bytesPerColumn; byteIdx++) {
          final value = blob.data[col * blob.bytesPerColumn + byteIdx];
          for (var bit = 0; bit < 8; bit++) {
            // MSB arriba, igual que en ESC/POS.
            final on = (value & (0x80 >> bit)) != 0;
            if (!on) continue;
            final y = yBase + byteIdx * 8 + bit;
            pixels[y * width + col] = true;
          }
        }
      }
    }

    return TicketImageOp(
      width: width,
      height: height,
      pixels: pixels,
      align: align,
    );
  }

  /// `GS v 0`: filas completas, `xBytes` bytes por fila, MSB a la izquierda.
  static TicketImageOp _rasterToOp(
    Uint8List data,
    int xBytes,
    int yDots,
    TicketAlign align,
  ) {
    final width = xBytes * 8;
    final pixels = List<bool>.filled(width * yDots, false);
    for (var y = 0; y < yDots; y++) {
      for (var xb = 0; xb < xBytes; xb++) {
        final value = data[y * xBytes + xb];
        for (var bit = 0; bit < 8; bit++) {
          if ((value & (0x80 >> bit)) == 0) continue;
          pixels[y * width + xb * 8 + bit] = true;
        }
      }
    }
    return TicketImageOp(
      width: width,
      height: yDots,
      pixels: pixels,
      align: align,
    );
  }
}

class _ImageBlob {
  const _ImageBlob({
    required this.columns,
    required this.bytesPerColumn,
    required this.data,
  });

  final int columns;
  final int bytesPerColumn;
  final Uint8List data;
}
