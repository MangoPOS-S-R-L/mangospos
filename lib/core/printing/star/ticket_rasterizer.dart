// Dibuja las operaciones de un ticket (ver `escpos_parser.dart`) sobre un
// lienzo monocromo del ancho del papel.
//
// CLAVE — celdas de ancho fijo:
//   Todo el layout de MangoPOS asume columnas de ancho fijo (48 a 80mm, 32 a
//   58mm): los `textRow`, los separadores y las tablas del cierre cuadran
//   porque cada carácter ocupa lo mismo. Para que el raster respete eso, el
//   texto se dibuja con una fuente monoespaciada y `letterSpacing` calibrado
//   para que el avance por carácter sea EXACTAMENTE el ancho de celda
//   (576/48 = 384/32 = 12 puntos). Sin eso, el ticket sale con las columnas
//   corridas aunque el texto sea correcto.
//
// El dibujo se hace en un solo Canvas y se lee una sola vez: el umbral de
// binarización convierte a 1 bit.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'escpos_parser.dart';
import 'mono_bitmap.dart';

class TicketRasterizer {
  /// Ancho de celda en puntos. 576/48 y 384/32 dan 12 en ambos papeles, así
  /// que el mismo valor sirve para 58mm y 80mm.
  static const int cellWidth = 12;

  /// Alto de celda. 12x24 es la proporción de la fuente A de una térmica.
  static const int cellHeight = 24;

  /// Tamaño de fuente que llena bien una celda de 24 puntos de alto.
  static const double _fontSize = 19;

  /// Sobre 0.5 de gris ya cuenta como punto negro. El texto se dibuja en
  /// negro puro sobre blanco, así que el umbral solo decide los bordes
  /// antialiaseados.
  static const int _threshold = 128;

  /// Rasteriza [ticket] para un papel de [dots] puntos de ancho.
  static Future<MonoBitmap> render(ParsedTicket ticket, int dots) async {
    final layout = _layout(ticket.ops, dots);
    final bitmap = MonoBitmap(dots);

    if (layout.height > 0) {
      final textPixels = await _paintText(layout, dots);
      bitmap.ensureHeight(layout.height);
      for (var y = 0; y < layout.height; y++) {
        for (var x = 0; x < dots; x++) {
          if (textPixels[y * dots + x]) bitmap.setPixel(x, y);
        }
      }
    }

    // Las imágenes (logo, QR) se pegan después, en su posición reservada.
    for (final placed in layout.images) {
      final op = placed.op;
      final dx = switch (op.align) {
        TicketAlign.center => ((dots - op.width) / 2).round(),
        TicketAlign.right => dots - op.width,
        TicketAlign.left => 0,
      };
      bitmap.blit(op.pixels, op.width, op.height, dx < 0 ? 0 : dx, placed.y);
    }

    bitmap.trimTrailingBlankRows();
    return bitmap;
  }

  // ── Layout ────────────────────────────────────────────────────────────

  static _Layout _layout(List<Object> ops, int dots) {
    final lines = <_PlacedLine>[];
    final images = <_PlacedImage>[];
    var y = 0;

    for (final op in ops) {
      if (op is TicketImageOp) {
        images.add(_PlacedImage(op: op, y: y));
        y += op.height;
        continue;
      }
      if (op is TicketTextOp) {
        final h = cellHeight * op.heightFactor;
        if (op.text.isNotEmpty || op.inverse) {
          lines.add(_PlacedLine(op: op, y: y));
        }
        y += h;
      }
    }

    return _Layout(lines: lines, images: images, height: y, dots: dots);
  }

  // ── Dibujo ────────────────────────────────────────────────────────────

  static Future<List<bool>> _paintText(_Layout layout, int dots) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, dots.toDouble(), layout.height.toDouble()),
    );
    // Fondo blanco: el papel. Sin esto el buffer queda transparente y el
    // umbral leería todo como blanco.
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, dots.toDouble(), layout.height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    for (final placed in layout.lines) {
      _paintLine(canvas, placed, dots);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(dots, layout.height);
    final byteData = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    picture.dispose();
    image.dispose();

    final out = List<bool>.filled(dots * layout.height, false);
    if (byteData == null) return out;
    final bytes = byteData.buffer.asUint8List();
    for (var i = 0; i < out.length; i++) {
      final o = i * 4;
      if (o + 2 >= bytes.length) break;
      // Luminancia rápida: si el punto es oscuro, es tinta.
      final lum = (bytes[o] * 30 + bytes[o + 1] * 59 + bytes[o + 2] * 11) ~/ 100;
      out[i] = lum < _threshold;
    }
    return out;
  }

  static void _paintLine(ui.Canvas canvas, _PlacedLine placed, int dots) {
    final op = placed.op;
    final cellW = (cellWidth * op.widthFactor).toDouble();
    final lineHeight = (cellHeight * op.heightFactor).toDouble();

    final chars = op.text.characters();
    final textWidth = chars.length * cellW;
    final startX = switch (op.align) {
      TicketAlign.center => ((dots - textWidth) / 2).clamp(0, dots.toDouble()),
      TicketAlign.right => (dots - textWidth).clamp(0, dots.toDouble()),
      TicketAlign.left => 0.0,
    };

    if (op.inverse) {
      // Franja invertida (las bandas "PARA LLEVAR" de la comanda): fondo
      // negro a todo el ancho de la línea y texto en blanco.
      canvas.drawRect(
        ui.Rect.fromLTWH(0, placed.y.toDouble(), dots.toDouble(), lineHeight),
        ui.Paint()..color = const ui.Color(0xFF000000),
      );
    }
    if (op.text.isEmpty) return;

    final color = op.inverse
        ? const ui.Color(0xFFFFFFFF)
        : const ui.Color(0xFF000000);
    final style = ui.TextStyle(
      color: color,
      fontSize: _fontSize * op.heightFactor,
      fontWeight: op.bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
      fontFamily: 'monospace',
      decoration: op.underline ? ui.TextDecoration.underline : null,
    );

    // Un párrafo POR CARÁCTER, cada uno centrado en su celda. Es lo que
    // garantiza que las columnas cuadren exactamente igual que en el papel
    // ESC/POS, sin depender de las métricas de la fuente del sistema.
    for (var i = 0; i < chars.length; i++) {
      final builder = ui.ParagraphBuilder(
        ui.ParagraphStyle(
          textAlign: ui.TextAlign.center,
          fontSize: _fontSize * op.heightFactor,
          fontFamily: 'monospace',
        ),
      )
        ..pushStyle(style)
        ..addText(chars[i]);
      final paragraph = builder.build()
        ..layout(ui.ParagraphConstraints(width: cellW));
      // Centrado vertical dentro de la celda.
      final dy = placed.y + (lineHeight - paragraph.height) / 2;
      canvas.drawParagraph(paragraph, ui.Offset(startX + i * cellW, dy));
    }
  }
}

extension on String {
  /// Split por unidades de código visibles. El ticket es Latin-1 (el
  /// generador ya normalizó comillas curvas y demás), así que basta con
  /// separar por runas.
  List<String> characters() => runes.map(String.fromCharCode).toList();
}

class _Layout {
  const _Layout({
    required this.lines,
    required this.images,
    required this.height,
    required this.dots,
  });

  final List<_PlacedLine> lines;
  final List<_PlacedImage> images;
  final int height;
  final int dots;
}

class _PlacedLine {
  const _PlacedLine({required this.op, required this.y});
  final TicketTextOp op;
  final int y;
}

class _PlacedImage {
  const _PlacedImage({required this.op, required this.y});
  final TicketImageOp op;
  final int y;
}

/// Alias para que el resto del código no importe `dart:typed_data` solo por
/// el tipo del buffer.
typedef RasterBytes = Uint8List;
