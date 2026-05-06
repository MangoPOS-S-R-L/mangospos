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

  /// [codeTable] envía comando ESC t con la tabla de caracteres del firmware.
  /// 16 = CP1252 (recomendado para español/acentos), valor por defecto.
  EscPosGenerator({
    this.paperWidth = 80,
    this.encoding = 'CP437',
    this.codeTable = 16,
  });

  /// Obtener comandos generados
  List<int> getCommands() => List.from(_buffer);

  /// Limpiar buffer
  void clear() => _buffer.clear();

  /// Append crudo al buffer. Se usa para inyectar bytes ESC/POS pre-generados
  /// (ej. una imagen raster del QR producida por QrEscPosBuilder). El caller
  /// es responsable de incluir los comandos de alineación si los necesita.
  void appendRaw(List<int> bytes) {
    if (bytes.isEmpty) return;
    _buffer.addAll(bytes);
  }

  // ============================================================
  // 🔧 COMANDOS BÁSICOS
  // ============================================================

  /// Inicializar impresora
  void initialize() {
    _buffer.addAll([ESC, 0x40]); // ESC @
    // Seleccionar tabla de caracteres para acentos/ñ
    _buffer.addAll([ESC, 0x74, codeTable]); // ESC t n
  }

  /// Salto de línea
  void lineFeed([int lines = 1]) {
    for (int i = 0; i < lines; i++) {
      _buffer.add(LF);
    }
  }

  /// Cortar papel
  void cut({bool partial = false}) {
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

  /// Seleccionar fuente (A = más grande, B = más densa/nítida)
  void setFont(Font font) {
    final value = font == Font.a ? 0 : 1; // ESC M n (0=A, 1=B)
    _buffer.addAll([ESC, 0x4D, value]);
  }

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
    // Por ahora usamos latin1, en producción usar encoding específico
    return latin1.encode(text);
  }

  int _getMaxChars() {
    final base = paperWidth == 80 ? 48 : 32;
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
