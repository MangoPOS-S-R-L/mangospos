// Layout de factura MODERNA (modelo `modern` del selector "Modelo de
// factura"). Es el equivalente en papel a lo que hacen las POS modernas
// tipo Square: ticket corto, jerarquía por tamaño y aire en blanco en vez
// de reglas `====`, y datos agrupados en lugar de una columna de etiquetas
// en MAYÚSCULAS.
//
// DE DÓNDE SALE EL AHORRO: del LAYOUT, no de exprimir la tipografía.
// Agrupar los metadatos en una línea, quitar la columna de etiquetas en
// mayúsculas y usar un solo tipo de separador deja el ticket en la mitad de
// renglones que el modelo estándar. Eso se nota en papel sin tocar lo que
// hace legible el texto.
//
// LO QUE SÍ SE TOCA DEL FIRMWARE, y por qué solo esto:
//
//  1. INTERLINEADO (`ESC 3 n`). El default de fábrica es 1/6" (~34 puntos)
//     para un glifo de 24: sobra aire. [bodyLineSpacing] lo ajusta sin
//     llegar a pegar los renglones.
//
//  2. DOBLE GOLPE (`ESC G 1`) SOLO en las dos líneas que deben resaltar
//     (nombre del negocio, TOTAL). En todo el ticket duplicaría el tiempo
//     de impresión; en dos líneas es gratis y las deja negras de verdad en
//     vez de gris-negrita.
//
// LO QUE SE PROBÓ Y SE REVIRTIÓ: la fuente B (`ESC M 1`, 9x17 en vez de
// 12x24) da 64 columnas y un ticket más angosto, pero son menos puntos por
// letra y en papel real se leyó peor — el dueño lo rechazó al verlo
// impreso. La fuente pequeña es una palanca de DENSIDAD, no de calidad.
//
// Las impresoras que no soportan alguno de estos comandos los ignoran y el
// ticket sale con su métrica de fábrica: más largo, nunca roto.
//
// Y EL TECHO DE TODO ESTO: por bien que se ajuste, el texto lo sigue
// dibujando la fuente de matriz de puntos del firmware. Para el acabado de
// una POS moderna hay que mandar el ticket como IMAGEN — ver
// `core/printing/star/esc_pos_raster_encoder.dart`.
//
// Este archivo SOLO dibuja. Todo el cálculo (totales, impuestos, descuento,
// consolidación de ítems) se queda en `print_ticket_service.dart` y llega
// aquí ya resuelto y formateado como String — para que no exista una
// segunda fórmula fiscal que pueda divergir de la del resto de modelos.

import 'esc_pos_generator.dart';

/// Un modificador ya resuelto: nombre y monto formateado (vacío = sin cargo).
typedef ModernModifier = ({String name, String amount});

class ModernInvoiceLayout {
  /// Interlineado del cuerpo, en puntos.
  ///
  /// La fuente A mide 24 puntos de alto, así que 32 deja 8 de aire. Es algo
  /// más apretado que el 1/6" de fábrica (~34) pero se sigue leyendo con
  /// holgura.
  ///
  /// HISTORIA, para que nadie lo vuelva a bajar "para ahorrar papel": la
  /// primera versión usaba fuente B con interlineado 26. Se veía mal en
  /// papel real — renglones pegados y letra pobre — y hubo que revertirlo.
  /// El ahorro de este modelo viene del LAYOUT (la mitad de renglones que
  /// el estándar), no de exprimir el interlineado.
  static const int bodyLineSpacing = EscPosGenerator.tightLineSpacing;

  /// Interlineado para las líneas en doble altura (48 puntos de glifo). El
  /// avance de papel es SIEMPRE el interlineado vigente, así que dejar el
  /// del cuerpo haría que el TOTAL se solape con la línea siguiente.
  static const int bigLineSpacing = EscPosGenerator.doubleHeightLineSpacing;

  /// Ancho del bloque de montos (totales y pagos), alineado a la derecha.
  /// Se recorta al ancho real disponible para que también entre a 58mm.
  static const int _amountBlock = 30;

  /// Sangría de los sub-detalles de un ítem (precio unitario, modificadores,
  /// nota). Son 4 espacios porque el nombre del producto arranca justo ahí:
  /// 2 de la columna de cantidad + 2 de separación.
  static const String _indent = '    ';

  /// Deja el generador en modo moderno.
  ///
  /// FUENTE A a propósito. La fuente B da 64 columnas en vez de 48 y hace el
  /// ticket más angosto, pero son 9x17 puntos contra 12x24: menos puntos por
  /// letra, o sea peor legibilidad en papel real — que es justo lo contrario
  /// de lo que se buscaba. La fuente pequeña es una palanca de DENSIDAD, no
  /// de calidad. A 48 columnas los nombres largos no se truncan porque este
  /// layout los envuelve (ver `_wrappedRow`).
  static void begin(EscPosGenerator gen) {
    gen.setFont(Font.a);
    gen.setLineSpacing(bodyLineSpacing);
  }

  /// Devuelve la impresora a su estado de fábrica. OBLIGATORIO antes del
  /// avance final y el corte: con el interlineado apretado, las líneas de
  /// avance previas al corte miden menos y la cuchilla llega a morder lo
  /// último impreso (ver `EscPosGenerator.safeCutFeedLines`).
  static void end(EscPosGenerator gen) {
    gen.resetLineSpacing();
    gen.setFont(Font.a);
  }

  /// Regla fina a todo el ancho. El modelo moderno usa UNA sola forma de
  /// separador (esta) en vez de alternar `-----` y `=====`.
  static void rule(EscPosGenerator gen) {
    gen.text('-' * gen.maxChars);
  }

  /// Nombre del negocio: la única línea del ticket en tamaño grande junto
  /// con el TOTAL.
  static void businessName(
    EscPosGenerator gen,
    String name, {
    required bool narrow,
  }) {
    gen.setLineSpacing(bigLineSpacing);
    gen.setTextSize(width: narrow ? 1 : 2, height: 2);
    gen.setBold(true);
    gen.setDoubleStrike(true);
    gen.textCenteredWrapped(name);
    gen.setDoubleStrike(false);
    gen.setBold(false);
    gen.setTextSize();
    gen.setLineSpacing(bodyLineSpacing);
  }

  /// Línea centrada en negrita (tipo de comprobante fiscal, título del
  /// documento). Sin asteriscos: el peso lo da la negrita.
  static void emphasisCentered(EscPosGenerator gen, String text) {
    gen.setBold(true);
    gen.textCenteredWrapped(text);
    gen.setBold(false);
  }

  /// Línea centrada normal (dirección, teléfono, RNC del negocio).
  static void centered(EscPosGenerator gen, String text) {
    gen.textCenteredWrapped(text);
  }

  /// Línea de metadatos compacta: `Orden A3F91B2C · Mesa 12 · Ana`.
  ///
  /// Sustituye la columna de `ORDEN:` / `MESA:` / `MESERO:` una debajo de
  /// otra, que a 64 columnas deja el 70% del renglón vacío. Los segmentos
  /// vacíos se descartan y el conjunto se envuelve por palabras.
  static void metaLine(EscPosGenerator gen, List<String> parts) {
    final clean = parts
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (clean.isEmpty) return;
    gen.textWrapped(clean.join(' · '));
  }

  /// Campo etiqueta + valor en una línea: `Cliente  JUAN PEREZ`. La etiqueta
  /// se separa por dos espacios en vez de rellenar hasta el borde derecho.
  static void field(EscPosGenerator gen, String label, String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    gen.textWrapped('$label  $v');
  }

  /// Un ítem de la factura.
  ///
  /// ```
  /// 2  Tacos al pastor                                    760.00
  ///      380.00 c/u
  ///      + Extra queso                                     50.00
  ///      Nota: sin cebolla
  /// ```
  ///
  /// El precio unitario solo aparece cuando la cantidad es distinta de 1:
  /// en una línea de 1 unidad, `380.00 c/u` debajo de `380.00` es ruido.
  static void item(
    EscPosGenerator gen, {
    required String qty,
    required String name,
    required String amount,
    String? unitPrice,
    bool isTakeout = false,
    List<ModernModifier> modifiers = const [],
    String note = '',
  }) {
    _wrappedRow(
      gen,
      '${qty.padRight(2)}  $name',
      amount,
      hangingIndent: _indent,
    );

    if (unitPrice != null && unitPrice.isNotEmpty) {
      gen.text('$_indent$unitPrice c/u');
    }
    if (isTakeout) {
      gen.setBold(true);
      gen.text('${_indent}Para llevar');
      gen.setBold(false);
    }
    for (final mod in modifiers) {
      if (mod.amount.isEmpty) {
        gen.textWrapped('$_indent+ ${mod.name}');
      } else {
        _wrappedRow(
          gen,
          '$_indent+ ${mod.name}',
          mod.amount,
          hangingIndent: '$_indent  ',
        );
      }
    }
    if (note.isNotEmpty) {
      gen.textWrapped('${_indent}Nota: $note');
    }
  }

  /// Fila del bloque de montos, pegada al margen derecho:
  /// `                              Subtotal      745.76`
  ///
  /// Va a la derecha (y no a lo ancho del papel) porque a 64 columnas un
  /// `Subtotal` en el borde izquierdo y su monto en el derecho quedan tan
  /// lejos que el ojo no los asocia.
  static void amountRow(
    EscPosGenerator gen,
    String label,
    String amount, {
    bool bold = false,
  }) {
    if (bold) gen.setBold(true);
    gen.textRight(_amountCells(gen, label, amount));
    if (bold) gen.setBold(false);
  }

  /// Regla corta sobre el TOTAL, del ancho del bloque de montos.
  static void amountRule(EscPosGenerator gen) {
    gen.textRight('-' * _blockWidth(gen));
  }

  /// El TOTAL: doble tamaño, negrita y doble golpe. Es la única línea que
  /// el cliente busca de un vistazo.
  static void total(
    EscPosGenerator gen,
    String label,
    String amount, {
    required bool narrow,
  }) {
    gen.setLineSpacing(bigLineSpacing);
    gen.setBold(true);
    gen.setDoubleStrike(true);
    gen.setTextSize(width: narrow ? 1 : 2, height: 2);
    // `maxChars` ya refleja el doble ancho, así que el bloque se recalcula
    // solo: 32 columnas a 80mm, 21 a 58mm.
    gen.textRight(_amountCells(gen, label, amount));
    gen.setTextSize();
    gen.setDoubleStrike(false);
    gen.setBold(false);
    gen.setLineSpacing(bodyLineSpacing);
  }

  // ── Internos ──────────────────────────────────────────────────────────

  static int _blockWidth(EscPosGenerator gen) {
    final max = gen.maxChars;
    return max < _amountBlock ? max : _amountBlock;
  }

  /// Compone `etiqueta ....... monto` dentro del bloque derecho. Si el monto
  /// solo no cabe (papel angosto + doble ancho), se devuelve el monto crudo:
  /// preferimos perder la etiqueta antes que truncar la cifra.
  static String _amountCells(EscPosGenerator gen, String label, String amount) {
    final width = _blockWidth(gen);
    if (amount.length >= width) return amount;
    final labelRoom = width - amount.length - 1;
    final shownLabel = label.length > labelRoom
        ? label.substring(0, labelRoom < 0 ? 0 : labelRoom)
        : label;
    return shownLabel + amount.padLeft(width - shownLabel.length);
  }

  /// Fila izquierda/derecha que, cuando el texto de la izquierda no cabe, lo
  /// envuelve por palabras en lugar de truncarlo. El monto se imprime en la
  /// ÚLTIMA línea del envoltorio.
  ///
  /// `textRow` del generador trunca a lo bruto, que es correcto para el
  /// modelo estándar (48 columnas, nombres cortos) pero deja "Sandwich de
  /// pechuga a la plan" en una factura moderna. Aquí el nombre completo es
  /// parte de lo que hace que el ticket se lea ordenado.
  static void _wrappedRow(
    EscPosGenerator gen,
    String left,
    String right, {
    String hangingIndent = '',
  }) {
    final room = gen.maxChars - right.length - 1;
    if (room <= 0 || left.length <= room) {
      gen.textRow(left, right);
      return;
    }

    final lines = _wrapToWidth(left, room, hangingIndent);
    for (var i = 0; i < lines.length - 1; i++) {
      gen.text(lines[i]);
    }
    gen.textRow(lines.last, right);
  }

  /// Envuelve [text] a [width] columnas sangrando las líneas siguientes con
  /// [indent]. Las palabras más largas que el ancho se parten a lo crudo:
  /// es preferible a que el firmware las corte en un punto arbitrario.
  static List<String> _wrapToWidth(String text, int width, String indent) {
    if (width <= 0) return [text];
    final words = text.trim().split(RegExp(r'\s+'));
    final lines = <String>[];
    var current = '';
    var prefix = '';

    void push() {
      if (current.isEmpty) return;
      lines.add(current);
      current = '';
      prefix = indent;
    }

    for (final word in words) {
      final candidate = current.isEmpty ? '$prefix$word' : '$current $word';
      if (candidate.length <= width) {
        current = candidate;
        continue;
      }
      push();
      var remaining = '$prefix$word';
      while (remaining.length > width) {
        lines.add(remaining.substring(0, width));
        remaining = '$indent${remaining.substring(width)}';
      }
      current = remaining;
    }
    push();
    return lines.isEmpty ? [text] : lines;
  }
}
