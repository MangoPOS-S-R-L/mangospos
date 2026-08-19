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

  /// AIRE entre renglones en modo proporcional, en puntos. Es el blanco que
  /// queda entre la tinta de una línea y la de la siguiente.
  ///
  /// El valor sale de MEDIR el papel que el dueño aprobó. Sobre la factura
  /// impresa el 2026-08-18 señaló el bloque TOTAL / Total USD / Efectivo:
  /// *"para mí ese es perfecto, así debería estar todo el espacio"*. Ese
  /// bloque tenía 61, 63 y 69 puntos de blanco — le sobraba aire porque
  /// llevaba renglones en blanco de más — contra los 19 a 25 del resto del
  /// ticket. De ahí estos 58: el mismo ritmo, ahora en TODO el ticket.
  ///
  /// HISTORIA, para que nadie lo baje sin imprimir: 26 → rechazado, 32 →
  /// rechazado, 38 → rechazado ("entre 2 líneas de texto es muy pegado").
  /// Este valor se calibra en papel, nunca en pantalla: a 203 dpi el ticket
  /// siempre se ve más denso impreso que en el mockup.
  ///
  /// LO QUE CUESTA: la factura de una mesa con logo y QR pasa de ~240mm a
  /// ~350mm de papel. Es la decisión del dueño, tomada viendo el rollo.
  static const int proportionalLeading = 58;

  /// Tamaño de fuente a 203 dpi. 24 puntos ≈ 3mm de altura de mayúscula, que
  /// es lo que se lee cómodo en un recibo térmico a un brazo de distancia.
  ///
  /// Ojo al subirlo: una línea de 48 columnas a 24 puntos ya roza el ancho
  /// del papel. Lo que impide que se desborde es el ajuste de
  /// [_fitToWidth] — sin él, el párrafo se parte en dos y la segunda mitad
  /// se dibuja ENCIMA del renglón siguiente, porque el alto ya está
  /// reservado.
  static const double _proportionalFontSize = 24;

  /// Alto de la caja del glifo como múltiplo del tamaño de fuente. Roboto
  /// pide ~1.17 entre ascendente y descendente; 1.25 deja el redondeo a
  /// favor para que el aire real nunca quede por debajo del pedido.
  static const double _glyphBoxRatio = 1.25;

  /// Avance de papel de un renglón proporcional: la caja del glifo (que
  /// crece con `GS !`) más el aire, que es CONSTANTE.
  ///
  /// El aire constante es lo que hace que el TOTAL en doble altura respire
  /// igual que el resto. Multiplicar el renglón entero por el factor de
  /// altura — que es lo que se hacía antes — le regalaba el doble de aire a
  /// la única línea que ya destacaba por tamaño.
  static int proportionalPitch(int heightFactor) =>
      (_proportionalFontSize * _glyphBoxRatio * heightFactor).round() +
      proportionalLeading;



  /// Grosor de las reglas finas que sustituyen a las filas de guiones.
  static const int _ruleThickness = 2;

  /// Fuente MONOESPACIADA del ticket, empaquetada en `pubspec.yaml`.
  ///
  /// La usa el camino de celdas fijas. Antes iba `fontFamily: 'monospace'`,
  /// que es un alias del sistema: Roboto Mono en Android, Menlo en Apple,
  /// Consolas en Windows. O sea, el mismo negocio imprimiendo con tres letras
  /// distintas según qué equipo mande el trabajo — y ninguna elegida.
  ///
  /// Tiene que ser de ancho fijo: este camino dibuja un carácter por celda de
  /// 12 puntos para que las columnas cuadren, y con una proporcional la `W` se
  /// sale de su celda y pisa a la vecina. Roboto Mono es la misma familia de
  /// diseño que la [_ticketFont] proporcional, así que los dos acabados del
  /// ticket se ven como el mismo producto.
  static const String _ticketMonoFont = 'RobotoTicketMono';

  /// Fuente PROPORCIONAL del ticket, empaquetada en `pubspec.yaml`.
  ///
  /// Va fija y no a la del sistema: sin esto el mismo negocio imprime con
  /// Roboto desde la caja Android y con SF desde un iPad. El nombre lleva
  /// sufijo para no pisar la `Roboto` que Android usa en la interfaz, que es
  /// la del sistema y está completa.
  static const String _ticketFont = 'RobotoTicket';

  /// Caracteres que, repetidos a lo ancho de la línea, son un separador
  /// dibujado con texto. En proporcional se cambian por una regla real:
  /// es lo que más acerca el ticket al de una POS moderna.
  static const String _ruleChars = '-=_.*~';

  /// Trazo y paso del separador punteado, en puntos. 3 de tinta cada 8 deja
  /// un punteado que se lee a 203 dpi sin parecer una línea gris.
  static const double _dottedDash = 3;
  static const double _dottedPeriod = 8;

  /// Aire arriba y abajo de cada imagen (logo, QR) en el flujo proporcional.
  ///
  /// Es MEDIO interlineado a cada lado, no un número suelto: así el logo y el
  /// QR quedan a la misma distancia de su vecino que cualquier par de líneas
  /// de texto. Con un valor propio, el ticket tenía dos ritmos — uno para el
  /// texto y otro, más suelto, alrededor de los gráficos.
  static const int _imageMargin = proportionalLeading ~/ 2;

  /// Alto del renglón de una regla: su propio trazo más el interlineado, que
  /// se reparte a los dos lados.
  ///
  /// Antes ocupaba un renglón entero de texto, así que quedaba con casi el
  /// doble de aire que el resto — que es exactamente lo que el dueño describió
  /// como "el espacio entre el lineado y los textos es amplio, pero entre 2
  /// líneas de texto es muy pegado".
  static int get _ruleLineHeight => _ruleThickness + proportionalLeading;

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
        final glyph = (op.fontB ? cellHeightB : cellHeight) * op.heightFactor;
        final h = _pitch(glyph, op);
        if (op.text.isNotEmpty || op.inverse) {
          lines.add(_PlacedLine(op: op, y: y, height: h));
        }
        y += h;
      }
    }

    return _Layout(lines: lines, images: images, height: y, dots: dots);
  }

  /// Avance de papel de una línea, en puntos.
  ///
  /// ESTO ES LO QUE DA EL AIRE DEL TICKET. Antes se avanzaba exactamente el
  /// alto del glifo (24 puntos para la fuente A), o sea CERO separación entre
  /// renglones: en papel los datos salían pegados unos encima de otros y la
  /// factura se leía como un bloque. El interlineado que el builder ya pedía
  /// por `ESC 3 n` — el mismo que respeta cualquier impresora por firmware —
  /// se estaba descartando en el camino rasterizado.
  ///
  /// El alto del glifo es el PISO cuando la línea tiene tinta: un `ESC 3`
  /// demasiado bajo en papel encima los renglones, y aquí preferimos no
  /// encimar tinta. Una línea vacía no tiene qué encimar, así que respeta el
  /// interlineado tal cual y sirve para medio renglón de aire.
  static int _pitch(int glyphHeight, TicketTextOp op) {
    final spacing = op.lineSpacing;
    if (spacing == null || spacing <= 0) return glyphHeight;
    final isBlank = op.text.isEmpty && !op.inverse;
    if (isBlank) return spacing;
    return spacing > glyphHeight ? spacing : glyphHeight;
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
    // El alto es el AVANCE de la línea, no el de la celda: el aire extra del
    // interlineado se reparte arriba y abajo del glifo, que es como queda en
    // una impresora por firmware.
    final lineHeight = placed.height.toDouble();
    final glyphHeight = (baseCellH * op.heightFactor).toDouble();

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
        ui.Rect.fromLTWH(
          0,
          placed.y + (lineHeight - glyphHeight) / 2,
          dots.toDouble(),
          glyphHeight,
        ),
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
      fontFamily: _ticketMonoFont,
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
                fontFamily: _ticketMonoFont,
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
        // El margen se mide contra la TINTA del gráfico, no contra su borde:
        // un QR trae 4 módulos de blanco obligatorios alrededor (la quiet
        // zone del estándar) y un logo PNG suele traer los suyos. Sumarle el
        // margen entero a ese blanco dejaba el QR a 77 puntos del texto
        // mientras el resto del ticket iba a 66.
        final (arriba, abajo) = _blankEdges(op);
        y += _marginAfterInk(arriba);
        images.add(_PlacedImage(op: op, y: y));
        y += op.height + _marginAfterInk(abajo);
        continue;
      }
      if (op is! TicketTextOp) continue;
      final isRule = _looksLikeRule(op.text);
      // Una regla no necesita el renglón completo: su "glifo" son 2 puntos de
      // trazo, y el aire se lo da el mismo interlineado que a todo lo demás.
      final height = isRule
          ? _ruleLineHeight
          : _pitch(proportionalPitch(op.heightFactor), op);
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
      final paint = ui.Paint()..color = black;

      // El carácter con el que se dibujó la regla en texto decide el trazo:
      // una fila de puntos pide una línea punteada y una de guiones, una
      // sólida. Así el layout sigue mandando desde el generador ESC/POS y
      // el mismo ticket se ve razonable aunque salga sin rasterizar.
      final dotted = op.text.trim().startsWith('.');
      if (dotted) {
        const period = _dottedPeriod;
        for (var x = 0.0; x < dots; x += period) {
          final w = (x + _dottedDash > dots) ? dots - x : _dottedDash;
          if (w <= 0) break;
          canvas.drawRect(
            ui.Rect.fromLTWH(x, top, w, _ruleThickness.toDouble()),
            paint,
          );
        }
      } else {
        canvas.drawRect(
          ui.Rect.fromLTWH(0, top, dots.toDouble(), _ruleThickness.toDouble()),
          paint,
        );
      }
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

    ui.Paragraph paragraph(String text, ui.TextAlign align, double size) {
      final builder =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(textAlign: align, fontSize: size),
            )
            ..pushStyle(
              ui.TextStyle(
                color: color,
                fontSize: size,
                fontWeight: op.bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
                decoration: op.underline ? ui.TextDecoration.underline : null,
                fontFamily: _ticketFont,
                // Sin esto el 1 es más angosto que el 8 y los importes
                // bailan entre filas: la columna de montos deja de leerse
                // como columna. Roboto trae las cifras tabulares.
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            )
            ..addText(text);
      return builder.build()
        ..layout(ui.ParagraphConstraints(width: dots.toDouble()));
    }

    ui.Paragraph build(String text, ui.TextAlign align) =>
        _fitToWidth(text, align, fontSize, dots, paragraph);

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
    //
    // TODO SE COLOCA SOBRE LA REJILLA DE CARACTERES del generador, que mide
    // 12 puntos por columna en los dos papeles (576/48 = 384/32 = 12). Es la
    // misma rejilla con la que el builder compuso la línea, así que la
    // factura cae en las mismas posiciones se rasterice o no.
    //
    // Antes se dibujaba la sangría como espacios de verdad y las columnas
    // intermedias se repartían por regla de tres sobre el largo de la línea.
    // Las dos cosas fallaban: un espacio proporcional mide la mitad que una
    // celda — el precio unitario no caía debajo del nombre del producto — y
    // la regla de tres sobre líneas cortas mandaba la sangría a cualquier
    // parte.
    final cell = ((op.fontB ? cellWidthB : cellWidth) * op.widthFactor)
        .toDouble();
    final columns = _splitColumns(op.text);
    final spans = _columnSpans(op.text);
    double dy(ui.Paragraph p) => line.y + (line.height - p.height) / 2;

    if (columns.length < 2 || spans.length != columns.length) {
      final p = build(op.text.trim(), ui.TextAlign.left);
      final left = spans.isEmpty ? 0.0 : spans.first.$1 * cell;
      canvas.drawParagraph(p, ui.Offset(left, dy(p)));
      return;
    }

    // Primera columna anclada donde arranca su texto: la sangría es lo que
    // distingue un sub-detalle (modificador, nota, precio unitario) de una
    // línea de producto.
    final first = build(columns.first, ui.TextAlign.left);
    canvas.drawParagraph(first, ui.Offset(spans.first.$1 * cell, dy(first)));

    final last = build(columns.last, ui.TextAlign.right);
    canvas.drawParagraph(last, ui.Offset(0, dy(last)));

    // Las intermedias, cada una por el lado que le toca: una cifra por la
    // derecha (o la columna baila en cuanto una fila trae 1 y la siguiente
    // 12) y un texto por la izquierda (o el nombre del producto se corre
    // según su largo — que es justo lo que se veía en el papel: "4x3 mille"
    // arrancaba antes que "4x3 coors original").
    for (var i = 1; i < columns.length - 1; i++) {
      if (_isNumericColumn(columns[i])) {
        final p = build(columns[i], ui.TextAlign.right);
        canvas.drawParagraph(
          p,
          ui.Offset(spans[i].$2 * cell - dots, dy(p)),
        );
      } else {
        final p = build(columns[i], ui.TextAlign.left);
        canvas.drawParagraph(p, ui.Offset(spans[i].$1 * cell, dy(p)));
      }
    }
  }

  /// ¿La columna es una CIFRA? Decide por qué lado se ancla.
  ///
  /// Se le quitan los símbolos de moneda antes de mirar, porque `RD$1,200.00`
  /// es una cifra aunque empiece por letras. Lo que queda con letras dentro
  /// es un nombre y va por la izquierda.
  static bool _isNumericColumn(String text) {
    final limpio = text.replaceAll(RegExp(r'(RD|US)?\$'), '').trim();
    if (limpio.isEmpty) return false;
    return RegExp(r'^[-+()%\d.,/ ]+$').hasMatch(limpio);
  }

  /// Filas en blanco al principio y al final de un gráfico.
  ///
  /// Son el blanco que la propia imagen ya trae: la quiet zone del QR, el
  /// margen de un logo mal recortado. Cuenta como aire y por eso se descuenta
  /// del margen (ver [_marginAfterInk]).
  static (int, int) _blankEdges(TicketImageOp op) {
    bool filaVacia(int y) {
      final base = y * op.width;
      for (var x = 0; x < op.width; x++) {
        if (op.pixels[base + x]) return false;
      }
      return true;
    }

    var arriba = 0;
    while (arriba < op.height && filaVacia(arriba)) {
      arriba++;
    }
    // Un gráfico entero en blanco no tiene "abajo": se evita contarlo dos
    // veces y que el margen se dispare.
    if (arriba >= op.height) return (op.height, 0);
    var abajo = 0;
    while (abajo < op.height && filaVacia(op.height - 1 - abajo)) {
      abajo++;
    }
    return (arriba, abajo);
  }

  /// Lo que falta para completar [_imageMargin] cuando el gráfico ya aporta
  /// [blanco] puntos de aire por su cuenta.
  static int _marginAfterInk(int blanco) {
    final falta = _imageMargin - blanco;
    return falta < 0 ? 0 : falta;
  }

  /// Compone el párrafo achicando la letra lo justo para que la línea quepa
  /// de una pieza en el papel.
  ///
  /// El alto del renglón ya está reservado ANTES de dibujar, así que una
  /// línea que no cabe no se sale por el costado: se parte en dos y la
  /// segunda mitad se dibuja encima del renglón siguiente. Pasa con el
  /// nombre largo de un negocio en doble tamaño, o con cualquier línea de 48
  /// columnas cuando se sube el tamaño de fuente.
  ///
  /// Se prefiere achicar esa línea concreta antes que bajarle el tamaño a
  /// todo el ticket por culpa del caso peor. El suelo del 60% evita que un
  /// texto absurdamente largo salga en letra ilegible: a partir de ahí se
  /// deja partir, que al menos se lee.
  static ui.Paragraph _fitToWidth(
    String text,
    ui.TextAlign align,
    double fontSize,
    int dots,
    ui.Paragraph Function(String, ui.TextAlign, double) build,
  ) {
    final p = build(text, align, fontSize);
    if (p.longestLine <= dots) return p;
    final factor = dots / p.longestLine;
    final shrunk = fontSize * (factor < 0.6 ? 0.6 : factor);
    return build(text, align, shrunk);
  }

  /// Índices `(inicio, fin)` de cada columna dentro de la línea, usando la
  /// misma regla que [_splitColumns]: rachas de 2+ espacios las separan.
  ///
  /// Existe además de `_splitColumns` porque para colocar las columnas
  /// intermedias no basta con su texto: hace falta saber DÓNDE las puso el
  /// generador.
  static List<(int, int)> _columnSpans(String text) {
    final spans = <(int, int)>[];
    var i = 0;
    while (i < text.length) {
      while (i < text.length && text[i] == ' ') {
        i++;
      }
      if (i >= text.length) break;
      final start = i;
      var lastNonSpace = i;
      while (i < text.length) {
        if (text[i] == ' ') {
          // Una racha de 2+ espacios cierra la columna; una sola es parte
          // del texto ("4x3 Blue Moon").
          if (i + 1 < text.length && text[i + 1] == ' ') break;
        } else {
          lastNonSpace = i;
        }
        i++;
      }
      spans.add((start, lastNonSpace + 1));
    }
    return spans;
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
  const _PlacedLine({required this.op, required this.y, required this.height});
  final TicketTextOp op;
  final int y;

  /// Avance de papel de la línea (ver `TicketRasterizer._pitch`). Puede ser
  /// mayor que la celda del glifo: esa diferencia es el aire del ticket.
  final int height;
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
