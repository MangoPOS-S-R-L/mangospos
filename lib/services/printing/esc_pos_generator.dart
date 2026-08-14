import 'dart:convert';

/// 🖨️ Generador de comandos ESC/POS
/// Genera comandos para impresoras térmicas
class EscPosGenerator {
  // Comandos ESC/POS básicos
  static const ESC = 0x1B;
  static const GS = 0x1D;
  static const LF = 0x0A;
  static const CR = 0x0D;

  final int paperWidth;
  final String encoding;
  final int codeTable;
  final List<int> _buffer = [];
  int _textWidthFactor = 1; // Factor de ampliación horizontal actual
  Font _font = Font.a; // Fuente vigente (cambia el ancho de celda)

  // ── Espejo en texto plano ────────────────────────────────────────────
  // Se llena en paralelo al buffer de bytes y NUNCA lo altera. Lo consume
  // el "modo sin impresora" (ver core/printing/printerless_mode.dart) para
  // mostrar el ticket en pantalla y exportarlo a PDF con el mismo layout
  // que saldría en papel.
  final List<String> _plainLines = [];
  final StringBuffer _plainLine = StringBuffer();
  Alignment _alignment = Alignment.left;

  /// [codeTable] envía comando ESC t con la tabla de caracteres del firmware.
  /// 16 = CP1252 (recomendado para español/acentos), valor por defecto.
  EscPosGenerator({
    this.paperWidth = 80,
    this.encoding = 'CP437',
    this.codeTable = 16,
  });

  /// Obtener comandos generados
  List<int> getCommands() => List.from(_buffer);

  /// Espejo del ticket en texto plano, con el mismo ancho de columnas y la
  /// misma alineación que saldría en papel. Lo usa el modo sin impresora
  /// para pintar el ticket en pantalla y exportarlo a PDF.
  ///
  /// No incluye gráficos (logo, QR): esos aparecen como el marcador que el
  /// caller pase en [appendRaw].
  String getPlainText() {
    final lines = [..._plainLines];
    final pending = _plainLine.toString();
    if (pending.isNotEmpty) lines.add(_alignPlain(pending));
    // Los feeds finales previos al corte no aportan nada en pantalla.
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }

  /// Limpiar buffer
  void clear() {
    _buffer.clear();
    _plainLines.clear();
    _plainLine.clear();
  }

  /// Append crudo al buffer. Se usa para inyectar bytes ESC/POS pre-generados
  /// (ej. una imagen raster del QR producida por QrEscPosBuilder). El caller
  /// es responsable de incluir los comandos de alineación si los necesita.
  ///
  /// [plainPlaceholder] es lo que el espejo de texto plano muestra en lugar
  /// del gráfico (ej. `[ QR de verificación DGII ]`). Null = el gráfico
  /// simplemente no aparece en pantalla.
  void appendRaw(List<int> bytes, {String? plainPlaceholder}) {
    if (bytes.isEmpty) return;
    _buffer.addAll(bytes);
    if (plainPlaceholder != null && plainPlaceholder.isNotEmpty) {
      _plainLine.write(plainPlaceholder);
      _flushPlainLine();
    }
  }

  // ============================================================
  // 🔧 COMANDOS BÁSICOS
  // ============================================================

  /// Inicializar impresora
  void initialize() {
    _buffer.addAll([ESC, 0x40]); // ESC @
    // ESC @ deja la impresora en fuente A, tamaño 1x e interlineado de
    // fábrica: el estado que rastreamos aquí tiene que seguirlo o `maxChars`
    // quedaría mintiendo tras un reset a mitad de ticket.
    _font = Font.a;
    _textWidthFactor = 1;
    // Seleccionar tabla de caracteres para acentos/ñ
    _buffer.addAll([ESC, 0x74, codeTable]); // ESC t n
  }

  /// Salto de línea
  void lineFeed([int lines = 1]) {
    for (int i = 0; i < lines; i++) {
      _buffer.add(LF);
      _flushPlainLine();
    }
  }

  /// Margen de avance (en lineas) que hay que dar ANTES de cortar.
  ///
  /// El cabezal y la cuchilla NO estan en el mismo punto del recorrido del
  /// papel: la cuchilla queda por delante del cabezal, entre ~10mm y ~25mm
  /// segun el modelo. `GS V` corta en la posicion actual, asi que si no se
  /// avanza papel la cuchilla parte POR ENCIMA de lo ultimo impreso y ese
  /// contenido se pierde. Esa distancia varia por impresora — por eso el
  /// mismo ticket sale completo en unas y cortado en otras.
  ///
  /// 5 lineas (~17mm a 24 dots/linea) cubren el gap del grueso de las
  /// termicas de 80mm sin desperdiciar papel de mas.
  static const int safeCutFeedLines = 5;

  /// Cortar papel. [feedLines] avanza papel antes del corte para que lo
  /// ultimo impreso pase la cuchilla (ver [safeCutFeedLines]).
  void cut({bool partial = false, int feedLines = 0}) {
    if (feedLines > 0) lineFeed(feedLines);
    _buffer.addAll([GS, 0x56, partial ? 1 : 0]); // GS V
  }

  /// Abrir cajón de dinero
  void openCashDrawer() {
    _buffer.addAll([ESC, 0x70, 0x00, 0x19, 0xFA]); // ESC p
  }

  // ============================================================
  // 📝 TEXTO
  // ============================================================

  /// Agregar texto
  void text(String text, {bool newLine = true}) {
    _buffer.addAll(_encodeText(text));
    _plainLine.write(text);
    if (newLine) lineFeed();
  }

  /// Texto centrado
  void textCentered(String text, {bool newLine = true}) {
    setAlignment(Alignment.center);
    this.text(text, newLine: newLine);
    setAlignment(Alignment.left);
  }

  /// Texto centrado con wrap automático por ancho disponible
  void textCenteredWrapped(String value) {
    final lines = _wrapText(value, _getMaxChars());
    setAlignment(Alignment.center);
    for (final line in lines) {
      text(line);
    }
    setAlignment(Alignment.left);
  }

  /// Texto alineado a la izquierda con wrap automático por palabras al ancho
  /// disponible. El firmware, si la línea se pasa, la corta en el carácter
  /// exacto donde se acaba el papel — a mitad de palabra. Esto la parte por
  /// espacios.
  ///
  /// La sangría inicial (si la hay) se conserva y se repite en cada línea
  /// del envoltorio, para que un sub-detalle indentado no se "desangre" al
  /// llegar a la segunda línea.
  void textWrapped(String value) {
    final indentLength = value.length - value.trimLeft().length;
    final indent = value.substring(0, indentLength);
    final width = _getMaxChars() - indentLength;
    if (width < 1) {
      text(value);
      return;
    }
    for (final line in _wrapText(value, width)) {
      text('$indent$line');
    }
  }

  /// Texto a la derecha
  void textRight(String text, {bool newLine = true}) {
    setAlignment(Alignment.right);
    this.text(text, newLine: newLine);
    setAlignment(Alignment.left);
  }

  /// Línea con texto a izquierda y derecha.
  ///
  /// Cuando [right] por sí solo excede el ancho del papel, antes este método
  /// crasheaba con "RangeError (end): Invalid value: Not in inclusive range
  /// 0..N: -X" porque hacía `left.substring(0, negative)`. Ahora se trunca
  /// el [right] primero si fuera necesario, y luego se calcula el espacio
  /// disponible para el [left] siempre con un end ≥ 0.
  void textRow(String left, String right) {
    final maxWidth = _getMaxChars();
    final clamped = _clampRow(left: left, right: right, maxWidth: maxWidth);
    text(clamped.left + (' ' * clamped.gap) + clamped.right);
  }

  /// Línea con relleno personalizado (p.ej. puntos) entre izquierda y derecha.
  /// Misma corrección de overflow que [textRow].
  void dotRow(String left, String right, {String fill = '.'}) {
    final maxWidth = _getMaxChars();
    final clamped = _clampRow(left: left, right: right, maxWidth: maxWidth);
    final filler = fill.isNotEmpty ? fill[0] : '.';
    final dots = clamped.gap < 1 ? 1 : clamped.gap;
    text(clamped.left + (filler * dots) + clamped.right);
  }

  /// Calcula left/right truncados y el gap entre ellos para que la línea
  /// completa quepa en [maxWidth] caracteres. Algoritmo:
  /// 1. Si [right] excede [maxWidth], lo trunca a [maxWidth] (caso patológico).
  /// 2. Calcula el espacio disponible para [left] = maxWidth - right.length - 1.
  /// 3. Si no queda espacio (<= 0), [left] queda vacío.
  /// 4. Si [left] excede el disponible, lo trunca.
  /// 5. El gap es siempre ≥ 0.
  ({String left, String right, int gap}) _clampRow({
    required String left,
    required String right,
    required int maxWidth,
  }) {
    String r = right;
    if (r.length > maxWidth) {
      r = r.substring(0, maxWidth);
    }
    final available = maxWidth - r.length - 1;
    String l;
    if (available <= 0) {
      l = '';
    } else if (left.length > available) {
      l = left.substring(0, available);
    } else {
      l = left;
    }
    final gap = maxWidth - l.length - r.length;
    return (left: l, right: r, gap: gap < 0 ? 0 : gap);
  }

  /// Línea separadora
  void separator({String char = '-'}) {
    final line = char * _getMaxChars();
    text(line);
  }

  /// Línea doble
  void doubleSeparator() {
    separator(char: '=');
  }

  // ============================================================
  // 🎨 FORMATO
  // ============================================================

  /// Establecer alineación
  void setAlignment(Alignment alignment) {
    int value;
    switch (alignment) {
      case Alignment.left:
        value = 0;
        break;
      case Alignment.center:
        value = 1;
        break;
      case Alignment.right:
        value = 2;
        break;
    }
    _buffer.addAll([ESC, 0x61, value]); // ESC a
    _alignment = alignment;
  }

  /// Establecer tamaño de texto
  void setTextSize({int width = 1, int height = 1}) {
    final safeWidth = width.clamp(1, 8);
    final safeHeight = height.clamp(1, 8);
    final w = (safeWidth - 1).clamp(0, 7);
    final h = (safeHeight - 1).clamp(0, 7);
    final value = (w << 4) | h;

    // Guardamos el factor para ajustar el ancho disponible en textRow
    _textWidthFactor = safeWidth;
    _buffer.addAll([GS, 0x21, value]); // GS !
  }

  /// Texto en negrita
  void setBold(bool enabled) {
    _buffer.addAll([ESC, 0x45, enabled ? 1 : 0]); // ESC E
  }

  /// Texto subrayado
  void setUnderline(bool enabled) {
    _buffer.addAll([ESC, 0x2D, enabled ? 1 : 0]); // ESC -
  }

  /// Texto invertido (blanco sobre negro)
  void setInverse(bool enabled) {
    _buffer.addAll([GS, 0x42, enabled ? 1 : 0]); // GS B
  }

  /// Doble impresión: cada línea se imprime dos veces con offset mínimo.
  /// Resultado: texto más oscuro/nítido, a costa de imprimir ~2x más
  /// lento. Universal en ESC/POS (ESC G n).
  void setDoubleStrike(bool enabled) {
    _buffer.addAll([ESC, 0x47, enabled ? 1 : 0]); // ESC G
  }

  /// Seleccionar fuente (A = 12x24 puntos, B = 9x17: más pequeña y fina).
  ///
  /// Cambiar de fuente cambia el ancho de celda y por lo tanto las columnas
  /// disponibles: a 80mm son 48 en A y 64 en B; a 58mm, 32 y 42. Por eso
  /// [maxChars] tiene que saber cuál está vigente — si no, los `textRow` de
  /// un ticket en fuente B saldrían alineados a 48 columnas dejando un
  /// hueco de 16 a la derecha.
  void setFont(Font font) {
    final value = font == Font.a ? 0 : 1; // ESC M n (0=A, 1=B)
    _buffer.addAll([ESC, 0x4D, value]);
    _font = font;
  }

  /// Interlineado en puntos (ESC 3 n). El default de fábrica es 1/6" (~30-34
  /// puntos según el modelo) pensado para la fuente A de 24 puntos de alto:
  /// deja ~25% de aire vertical en CADA línea. Bajarlo es la palanca más
  /// directa para que el ticket salga más corto sin quitarle información.
  ///
  /// Ojo: el avance de papel es el que se fije aquí, así que una línea en
  /// doble altura (48 puntos) con interlineado 24 se solapa con la siguiente.
  /// Antes de un bloque en `setTextSize(height: 2)` hay que subir el valor o
  /// volver al default con [resetLineSpacing].
  ///
  /// Las impresoras que no soportan el comando lo ignoran y siguen con su
  /// interlineado de fábrica: el ticket sale como hoy, nunca roto.
  void setLineSpacing(int dots) {
    final safe = dots.clamp(0, 255);
    _buffer.addAll([ESC, 0x33, safe]); // ESC 3 n
  }

  /// Volver al interlineado de fábrica (ESC 2).
  void resetLineSpacing() {
    _buffer.addAll([ESC, 0x32]); // ESC 2
  }

  /// Interlineado de los modelos de ticket "apretados" (compacto, simple y
  /// moderno), en puntos.
  ///
  /// La fuente A mide 24 puntos de alto y el default de fábrica es 1/6"
  /// (~34): sobra aire. 32 deja 8 puntos de separación — algo más ajustado
  /// que de fábrica y todavía cómodo de leer.
  ///
  /// NO BAJARLO "para que quepa más". Ya se probó con 26 y el resultado en
  /// papel fueron renglones pegados que hubo que revertir. El ahorro de
  /// estos modelos viene del layout (menos renglones), no de exprimir el
  /// interlineado.
  static const int tightLineSpacing = 32;

  /// Interlineado para las líneas en doble altura (48 puntos de glifo).
  ///
  /// El avance de papel es SIEMPRE el interlineado vigente: dejar el del
  /// cuerpo en una línea 2x hace que se solape con la siguiente. Hay que
  /// subirlo antes del bloque grande y devolverlo después.
  static const int doubleHeightLineSpacing = 60;

  /// Cambiar tabla de caracteres en caliente (ESC t n)
  void setCodeTable(int table) {
    _buffer.addAll([ESC, 0x74, table]);
  }

  // ============================================================
  // 🎫 TEMPLATES DE TICKETS
  // ============================================================

  /// Header de ticket
  void ticketHeader({
    required String businessName,
    String? address,
    String? phone,
    String? rnc,
  }) {
    initialize();
    lineFeed();

    setTextSize(width: 2, height: 2);
    setBold(true);
    textCentered(businessName);
    setBold(false);
    setTextSize();

    if (address != null) textCentered(address, newLine: false);
    if (phone != null) textCentered('Tel: $phone', newLine: false);
    if (rnc != null) textCentered('RNC: $rnc', newLine: false);

    lineFeed();
    doubleSeparator();
  }

  /// Footer de ticket
  void ticketFooter({String? message}) {
    doubleSeparator();
    if (message != null) {
      textCentered(message);
    }
    textCentered('¡Gracias por su preferencia!');
    lineFeed(3);
  }

  /// Información de orden
  void orderInfo({
    required String orderNumber,
    String? tableName,
    required DateTime dateTime,
    String? waiterName,
  }) {
    setBold(true);
    text('ORDEN: $orderNumber');
    setBold(false);

    final resolvedTable = tableName?.trim();
    if (resolvedTable != null && resolvedTable.isNotEmpty) {
      text('Mesa: $resolvedTable');
    }

    final resolvedWaiter = waiterName?.trim();
    if (resolvedWaiter != null && resolvedWaiter.isNotEmpty) {
      text('Mesero: $resolvedWaiter');
    }

    text('Fecha: ${_formatDateTime(dateTime)}');

    separator();
  }

  /// Item de orden
  void orderItem({
    required String name,
    required double quantity,
    double? price,
    List<String>? modifiers,
    String? notes,
  }) {
    // Cantidad y nombre
    final qtyStr = 'x${quantity.toInt()}';
    final priceStr = price != null ? 'RD\$ ${price.toStringAsFixed(2)}' : '';

    if (price != null) {
      textRow('$qtyStr $name', priceStr);
    } else {
      text('$qtyStr $name');
    }

    // Modificadores
    if (modifiers != null && modifiers.isNotEmpty) {
      for (final mod in modifiers) {
        text('  + $mod');
      }
    }

    // Notas
    if (notes != null && notes.isNotEmpty) {
      setTextSize(width: 1, height: 1);
      text('  Nota: $notes');
      setTextSize();
    }
  }

  /// Resumen de totales
  ///
  /// PRD 2: el desglose de impuestos viene como [taxBreakdown] (lista de
  /// `(label, amount)`), no como campos separados ITBIS/Servicio. Cada
  /// línea se imprime tal cual viene del breakdown, lo que permite
  /// soportar cualquier impuesto configurado en el negocio (ITBIS,
  /// Propina Ley, ITC, etc.) sin tocar este código.
  ///
  /// Para compat con call-sites legacy (pre-PRD-2) que aún pasan `tax` y
  /// `serviceFee`, se acepta también esa firma; en ese caso se construye
  /// un breakdown ad-hoc con los valores recibidos.
  void totals({
    required double subtotal,
    double? discounts,
    List<({String label, double amount})>? taxBreakdown,
    // Legacy: usar `taxBreakdown` en su lugar.
    double? serviceFee,
    double? tax,
    required double total,

    /// Etiqueta del subtotal. Default 'Subtotal:'. Para e-CF DGII se debe
    /// pasar 'Subtotal Gravado:' (estandar Norma General 01-2020).
    String subtotalLabel = 'Subtotal:',
  }) {
    separator();

    textRow(subtotalLabel, 'RD\$ ${subtotal.toStringAsFixed(2)}');

    if (discounts != null && discounts > 0) {
      textRow('Descuentos:', '-RD\$ ${discounts.toStringAsFixed(2)}');
    }

    // Desglose nuevo (post-PRD-2): cada impuesto como línea propia.
    if (taxBreakdown != null && taxBreakdown.isNotEmpty) {
      for (final line in taxBreakdown) {
        if (line.amount.abs() < 0.005) continue;
        textRow('${line.label}:', 'RD\$ ${line.amount.toStringAsFixed(2)}');
      }
    } else {
      // Fallback legacy: mantener layout viejo (Servicio + ITBIS) cuando el
      // caller no provee breakdown estructurado.
      if (serviceFee != null && serviceFee > 0) {
        textRow('Servicio:', 'RD\$ ${serviceFee.toStringAsFixed(2)}');
      }
      if (tax != null) {
        textRow('ITBIS (18%):', 'RD\$ ${tax.toStringAsFixed(2)}');
      }
    }

    doubleSeparator();

    setBold(true);
    setTextSize(width: 2, height: 2);
    textRow('TOTAL:', 'RD\$ ${total.toStringAsFixed(2)}');
    setTextSize();
    setBold(false);
  }

  /// Información de pago
  void paymentInfo({
    required String method,
    required double amount,
    double? change,
    String? reference,
  }) {
    separator();

    text('MÉTODO DE PAGO: $method');
    textRow('Monto recibido:', 'RD\$ ${amount.toStringAsFixed(2)}');

    if (change != null && change > 0) {
      setBold(true);
      textRow('Cambio:', 'RD\$ ${change.toStringAsFixed(2)}');
      setBold(false);
    }

    if (reference != null) {
      text('Referencia: $reference');
    }
  }

  /// Información fiscal
  void fiscalInfo({
    required String ncf,
    required String ncfType,
    String? customerName,
    String? customerRnc,
  }) {
    separator();

    setBold(true);
    text('NCF: $ncf');
    setBold(false);

    text('Tipo: $ncfType');

    if (customerName != null) {
      text('Cliente: $customerName');
    }

    if (customerRnc != null) {
      text('RNC Cliente: $customerRnc');
    }
  }

  // ============================================================
  // 🔧 UTILIDADES
  // ============================================================

  List<int> _encodeText(String text) {
    // Normalización defensiva: iOS/macOS/Word insertan "smart quotes"
    // (U+2018/U+2019/U+201C/U+201D), em-dashes, ellipsis, etc. al
    // teclear. Esos caracteres NO están en Latin-1 y `latin1.encode`
    // tira FormatException sin atrapar, lo que rompía la impresión de
    // cierres de caja en negocios cuyo nombre contiene apostrofo
    // (e.g. "Hailey's", "D'Angelo") tipeado desde iPhone.
    //
    // Mapeamos los caracteres más comunes a su equivalente ASCII y
    // dejamos `allowInvalid: true` como red de seguridad para cualquier
    // otro caracter exótico (queda como '?' en lugar de tirar excepción).
    final normalized = text
        .replaceAll('‘', "'") // ‘  left single quote
        .replaceAll('’', "'") // ’  right single quote / apostrophe
        .replaceAll('‚', "'") // ‚  single low-9 quote
        .replaceAll('‛', "'") // ‛  single high-reversed-9 quote
        .replaceAll('“', '"') // “  left double quote
        .replaceAll('”', '"') // ”  right double quote
        .replaceAll('„', '"') // „  double low-9 quote
        .replaceAll('–', '-') // –  en-dash
        .replaceAll('—', '-') // —  em-dash
        .replaceAll('…', '...') // …  horizontal ellipsis
        .replaceAll('≈', '~') // ≈  approximately equal (U+2248)
        .replaceAll('≠', '!=') // ≠  not equal (U+2260)
        .replaceAll('≤', '<=') // ≤  less-than-or-equal (U+2264)
        .replaceAll('≥', '>=') // ≥  greater-than-or-equal (U+2265)
        .replaceAll(' ', ' '); // nbsp → espacio normal
    // `allowInvalid: true` se setea en el codec (no en el método encode),
    // así caracteres exóticos no normalizados arriba salen como '?' en
    // lugar de tirar FormatException y matar la impresión.
    return const Latin1Codec(allowInvalid: true).encode(normalized);
  }

  /// Cierra la línea en curso del espejo plano y la empuja a [_plainLines]
  /// aplicando la alineación vigente. Se llama desde [lineFeed], que es por
  /// donde pasan TODOS los saltos de línea del generador.
  void _flushPlainLine() {
    final content = _plainLine.toString();
    _plainLine.clear();
    _plainLines.add(content.isEmpty ? '' : _alignPlain(content));
  }

  /// Rellena con espacios para emular la alineación que hace el firmware.
  /// El ancho es el mismo `_getMaxChars()` que usa `textRow`, así que las
  /// líneas de doble tamaño quedan en su ancho real de columnas.
  String _alignPlain(String content) {
    if (_alignment == Alignment.left) return content;
    final cols = _getMaxChars();
    final trimmed = content.trimRight();
    if (trimmed.length >= cols) return trimmed;
    // El hueco se mide en CELDAS del papel, no en caracteres de la línea:
    // con `setTextSize(width: 2)` cada carácter ocupa dos celdas, así que un
    // título centrado en 24 columnas arranca a 9 celdas del borde, no a 4.
    // Sin esta corrección el espejo (modo sin impresora, PDF) mostraba las
    // líneas grandes corridas a la izquierda respecto del papel.
    final padCells = (cols - trimmed.length) * _textWidthFactor;
    if (_alignment == Alignment.right) {
      return (' ' * padCells) + trimmed;
    }
    return (' ' * (padCells ~/ 2)) + trimmed;
  }

  /// Columnas disponibles en la línea AHORA mismo, ya descontados el factor
  /// de ampliación horizontal (`setTextSize`) y la fuente vigente
  /// (`setFont`). A 80mm son 48 en fuente A y 64 en fuente B (24 y 32 a
  /// doble ancho); a 58mm, 32 y 42.
  ///
  /// Los builders de tickets lo usan para no hardcodear 48/24: así el mismo
  /// layout sirve para 58mm y para fuente B sin duplicar código.
  int get maxChars => _getMaxChars();

  /// Fuente vigente. La usan los builders que necesitan decidir métricas
  /// (p.ej. cuánto sangrar un sub-detalle) sin volver a leer el buffer.
  Font get font => _font;

  int _getMaxChars() {
    // Cabezal de 576 puntos a 80mm y 384 a 58mm. Fuente A ocupa 12 puntos
    // por celda; fuente B, 9 (576/9 = 64, 384/9 = 42).
    final base = _font == Font.b
        ? (paperWidth == 80 ? 64 : 42)
        : (paperWidth == 80 ? 48 : 32);
    final cols = (base / _textWidthFactor).floor();
    return cols > 0 ? cols : 1;
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  List<String> _wrapText(String value, int maxChars) {
    final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return [''];
    if (normalized.length <= maxChars) return [normalized];

    final words = normalized.split(' ');
    final lines = <String>[];
    var current = '';

    for (final word in words) {
      if (word.length > maxChars) {
        if (current.isNotEmpty) {
          lines.add(current);
          current = '';
        }
        for (var i = 0; i < word.length; i += maxChars) {
          final end = (i + maxChars < word.length) ? i + maxChars : word.length;
          lines.add(word.substring(i, end));
        }
        continue;
      }

      final candidate = current.isEmpty ? word : '$current $word';
      if (candidate.length <= maxChars) {
        current = candidate;
      } else {
        if (current.isNotEmpty) lines.add(current);
        current = word;
      }
    }

    if (current.isNotEmpty) {
      lines.add(current);
    }

    return lines;
  }
}

/// Alineación de texto
enum Alignment { left, center, right }

/// Fuente ESC/POS
enum Font { a, b }
