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
  /// Ancho de celda en puntos para la fuente A. 576/48 y 384/32 dan 12 en
  /// ambos papeles, así que el mismo valor sirve para 58mm y 80mm.
  static const int cellWidth = 12;

  /// Alto de celda. 12x24 es la proporción de la fuente A de una térmica.
  static const int cellHeight = 24;

  /// Idem para la fuente B (`ESC M 1`), de 9x17 puntos: 64 columnas a 80mm
  /// y 42 a 58mm. La usa el modelo de factura moderno.
  static const int cellWidthB = 9;
  static const int cellHeightB = 18;

  /// Tamaño de fuente que llena bien una celda de 24 puntos de alto.
  static const double _fontSize = 19;

  /// Idem para la celda de 18 puntos de la fuente B.
  static const double _fontSizeB = 14;

  /// Sobre 0.5 de gris ya cuenta como punto negro. El texto se dibuja en
  /// negro puro sobre blanco, así que el umbral solo decide los bordes
  /// antialiaseados.
  static const int _threshold = 128;

  // ── Modo proporcional (calidad tipo Square) ──────────────────────────
  //
  // El modo por defecto dibuja cada carácter en una celda fija, para
  // reproducir al punto el layout de columnas del papel. Es correcto, pero
  // se ve igual de "matriz de puntos" que el firmware — solo que dibujado
  // por nosotros.
  //
  // El modo proporcional cambia eso: tipografía real del sistema, ancho
  // variable por carácter y negrita de verdad. Para que las columnas sigan
  // cuadrando sin ancho fijo, se aprovecha que TODOS los builders separan
  // las columnas con 2+ espacios (`textRow` rellena hasta el borde): esa
  // racha de espacios se lee como "esto va a la derecha".

  /// Alto de renglón en modo proporcional. Da aire suficiente para acentos
  /// y descendentes sin el derroche del interlineado de fábrica.
  static const int proportionalLineHeight = 26;

  /// Tamaño de fuente que llena bien ese renglón a 203 dpi.
  static const double _proportionalFontSize = 20;

  /// Grosor de las reglas finas que sustituyen a las filas de guiones.
  static const int _ruleThickness = 2;

  /// Caracteres que, repetidos a lo ancho de la línea, son un separador
  /// dibujado con texto. En proporcional se cambian por una regla real:
  /// es lo que más acerca el ticket al de una POS moderna.
  static const String _ruleChars = '-=_.*~';

  /// Rasteriza [ticket] para un papel de [dots] puntos de ancho.
  ///
  /// [proportional] activa la tipografía real (ver arriba). Por defecto va en
  /// false: las Star TSP100 llevan años saliendo con celdas fijas y no se
  /// cambia su salida sin que alguien lo pida.
  static Future<MonoBitmap> render(
    ParsedTicket ticket,
    int dots, {
    bool proportional = false,
  }) async {
    if (proportional) return _renderProportional(ticket, dots);
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
        final h = (op.fontB ? cellHeightB : cellHeight) * op.heightFactor;
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
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    picture.dispose();
    image.dispose();

    final out = List<bool>.filled(dots * layout.height, false);
    if (byteData == null) return out;
    final bytes = byteData.buffer.asUint8List();
    for (var i = 0; i < out.length; i++) {
      final o = i * 4;
      if (o + 2 >= bytes.length) break;
      // Luminancia rápida: si el punto es oscuro, es tinta.
      final lum =
          (bytes[o] * 30 + bytes[o + 1] * 59 + bytes[o + 2] * 11) ~/ 100;
      out[i] = lum < _threshold;
    }
    return out;
  }

  static void _paintLine(ui.Canvas canvas, _PlacedLine placed, int dots) {
    final op = placed.op;
    final baseCellW = op.fontB ? cellWidthB : cellWidth;
    final baseCellH = op.fontB ? cellHeightB : cellHeight;
    final baseSize = op.fontB ? _fontSizeB : _fontSize;
    final cellW = (baseCellW * op.widthFactor).toDouble();
    final lineHeight = (baseCellH * op.heightFactor).toDouble();

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
      fontSize: baseSize * op.heightFactor,
      fontWeight: op.bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
      fontFamily: 'monospace',
      decoration: op.underline ? ui.TextDecoration.underline : null,
    );

    // Un párrafo POR CARÁCTER, cada uno centrado en su celda. Es lo que
    // garantiza que las columnas cuadren exactamente igual que en el papel
    // ESC/POS, sin depender de las métricas de la fuente del sistema.
    for (var i = 0; i < chars.length; i++) {
      final builder =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(
                textAlign: ui.TextAlign.center,
                fontSize: baseSize * op.heightFactor,
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

  // ── Proporcional ──────────────────────────────────────────────────────

  static Future<MonoBitmap> _renderProportional(
    ParsedTicket ticket,
    int dots,
  ) async {
    final lines = <_ProportionalLine>[];
    final images = <_PlacedImage>[];
    var y = 0;

    for (final op in ticket.ops) {
      if (op is TicketImageOp) {
        images.add(_PlacedImage(op: op, y: y));
        y += op.height;
        continue;
      }
      if (op is! TicketTextOp) continue;
      final isRule = _looksLikeRule(op.text);
      // Una regla no necesita el renglón completo; el aire lo dan los
      // márgenes que se le suman arriba y abajo.
      final height = isRule
          ? proportionalLineHeight
          : (proportionalLineHeight * op.heightFactor);
      if (op.text.isNotEmpty || op.inverse) {
        lines.add(
          _ProportionalLine(op: op, y: y, height: height, isRule: isRule),
        );
      }
      y += height;
    }

    final bitmap = MonoBitmap(dots);
    if (y > 0) {
      final pixels = await _paintProportional(lines, dots, y);
      bitmap.ensureHeight(y);
      for (var py = 0; py < y; py++) {
        for (var px = 0; px < dots; px++) {
          if (pixels[py * dots + px]) bitmap.setPixel(px, py);
        }
      }
    }

    for (final placed in images) {
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

  static Future<List<bool>> _paintProportional(
    List<_ProportionalLine> lines,
    int dots,
    int height,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, dots.toDouble(), height.toDouble()),
    );
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, dots.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    for (final line in lines) {
      _paintProportionalLine(canvas, line, dots);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(dots, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    picture.dispose();
    image.dispose();

    final out = List<bool>.filled(dots * height, false);
    if (byteData == null) return out;
    final bytes = byteData.buffer.asUint8List();
    for (var i = 0; i < out.length; i++) {
      final o = i * 4;
      if (o + 2 >= bytes.length) break;
      final lum =
          (bytes[o] * 30 + bytes[o + 1] * 59 + bytes[o + 2] * 11) ~/ 100;
      out[i] = lum < _threshold;
    }
    return out;
  }

  static void _paintProportionalLine(
    ui.Canvas canvas,
    _ProportionalLine line,
    int dots,
  ) {
    final op = line.op;
    final black = const ui.Color(0xFF000000);

    // Las filas de guiones se cambian por una regla real, centrada en el
    // renglón. Es lo que más acerca el ticket al de una POS moderna.
    if (line.isRule) {
      final top = line.y + (line.height - _ruleThickness) / 2;
      canvas.drawRect(
        ui.Rect.fromLTWH(0, top, dots.toDouble(), _ruleThickness.toDouble()),
        ui.Paint()..color = black,
      );
      return;
    }

    if (op.inverse) {
      canvas.drawRect(
        ui.Rect.fromLTWH(
          0,
          line.y.toDouble(),
          dots.toDouble(),
          line.height.toDouble(),
        ),
        ui.Paint()..color = black,
      );
    }
    if (op.text.trim().isEmpty) return;

    final color = op.inverse ? const ui.Color(0xFFFFFFFF) : black;
    final fontSize = _proportionalFontSize * op.heightFactor;

    ui.Paragraph build(String text, ui.TextAlign align) {
      final builder =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(textAlign: align, fontSize: fontSize),
            )
            ..pushStyle(
              ui.TextStyle(
                color: color,
                fontSize: fontSize,
                fontWeight: op.bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
                decoration: op.underline ? ui.TextDecoration.underline : null,
                // Sin fontFamily: la fuente por defecto del sistema (Roboto en
                // Android, SF en Apple, Segoe en Windows). Todas son sans
                // reales y a 203 dpi cualquiera supera de lejos a la matriz de
                // puntos del firmware. Contra: el ticket no sale idéntico entre
                // plataformas. Se acepta a cambio de no empaquetar un TTF.
              ),
            )
            ..addText(text);
      return builder.build()
        ..layout(ui.ParagraphConstraints(width: dots.toDouble()));
    }

    // Centrado y derecha se dibujan de una pieza: partirlos en columnas
    // rompería el bloque de totales, que YA viene alineado a la derecha
    // como una sola cadena.
    if (op.align != TicketAlign.left) {
      final p = build(
        op.text.trim(),
        op.align == TicketAlign.center
            ? ui.TextAlign.center
            : ui.TextAlign.right,
      );
      canvas.drawParagraph(
        p,
        ui.Offset(0, line.y + (line.height - p.height) / 2),
      );
      return;
    }

    // Izquierda: las rachas de 2+ espacios que dejan `textRow`/`dotRow` al
    // rellenar hasta el borde son la marca de "esto va a la derecha".
    final columns = _splitColumns(op.text);
    if (columns.length < 2) {
      final p = build(op.text.trimRight(), ui.TextAlign.left);
      canvas.drawParagraph(
        p,
        ui.Offset(0, line.y + (line.height - p.height) / 2),
      );
      return;
    }

    // La sangría inicial se conserva: es lo que distingue un sub-detalle
    // (modificador, nota) de una línea de producto.
    final indent = op.text.length - op.text.trimLeft().length;
    final left = build('${' ' * indent}${columns.first}', ui.TextAlign.left);
    final right = build(columns.last, ui.TextAlign.right);
    canvas.drawParagraph(
      left,
      ui.Offset(0, line.y + (line.height - left.height) / 2),
    );
    canvas.drawParagraph(
      right,
      ui.Offset(0, line.y + (line.height - right.height) / 2),
    );
  }

  /// ¿La línea es una fila de caracteres de separación (`-----`, `=====`)?
  static bool _looksLikeRule(String text) {
    final t = text.trim();
    if (t.length < 4) return false;
    final first = t[0];
    if (!_ruleChars.contains(first)) return false;
    return t.split('').every((c) => c == first);
  }

  /// Parte una línea en columnas usando las rachas de 2+ espacios.
  static List<String> _splitColumns(String text) {
    return text
        .split(RegExp(r' {2,}'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
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

/// Una línea de texto proporcional ya resuelta: estilo, posición y si en
/// realidad era un separador que hay que dibujar como regla.
class _ProportionalLine {
  const _ProportionalLine({
    required this.op,
    required this.y,
    required this.height,
    required this.isRule,
  });

  final TicketTextOp op;
  final int y;
  final int height;
  final bool isRule;
}
