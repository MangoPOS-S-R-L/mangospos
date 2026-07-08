import 'package:decimal/decimal.dart';

import '../../data/models/bank_account.dart';
import '../../data/models/business_profile.dart';
import '../../data/models/printing_models.dart';
import '../../data/models/order_item_tax_line.dart';
import '../../data/models/sales_models.dart';
import '../../data/models/payment_models.dart';
import '../../core/utils/app_time.dart';
import '../../core/currency/business_currency.dart';
import '../../core/currency/usd_conversion.dart';
import '../../core/currency/usd_display_settings.dart';
import '../../data/utils/order_pricing_utils.dart';
import 'esc_pos_generator.dart';

/// 🖨️ Servicio de generación de tickets
class PrintTicketService {
  /// Moneda activa del negocio para formatear montos en los tickets. Se fija
  /// al inicio de cada método público de generación (síncrono, sin await entre
  /// el set y su uso, así que no hay carrera dentro de una misma generación).
  /// Default DOP preserva el comportamiento legacy (`RD$`).
  static BusinessCurrency _currency = BusinessCurrency.fallbackDop;
  /// Total base de la línea (sin impuestos) para impresión de tickets.
  /// Usar este en lugar de `itemDisplayTotal` para que la suma de líneas
  /// coincida con el SUBTOTAL y el desglose de impuestos aparezca una sola
  /// vez en el footer. `preferStoredItemTotals` se ignora aquí porque
  /// `item.total` es gross (con impuestos) y rompería la consistencia.
  static double _resolvePrintableItemTotal(
    Order? order,
    OrderItem item, {
    bool preferStoredItemTotals = false,
  }) {
    return itemDisplayBaseTotal(order, item);
  }

  static double _resolvePrintableItemUnitPrice(
    Order? order,
    OrderItem item, {
    bool preferStoredItemTotals = false,
  }) {
    return itemDisplayBaseUnitPrice(order, item);
  }

  /// Base imprimible por línea, consistente con el SUBTOTAL recomputado del
  /// ticket. Cuando el ticket recomputa el SUBTOTAL desde el TOTAL (tasa
  /// uniforme conocida) y el ítem es inclusive, derivamos la base de la línea
  /// con la MISMA fórmula para que la suma de líneas cuadre con el SUBTOTAL:
  ///   - post_discount: base = (gross - descuento) / (1 + tasa)
  ///   - pre_discount:  base = gross / (1 + tasa)  (descuento sale aparte)
  /// Necesario porque `item.subtotal` del backend resta el descuento
  /// tax-inclusive a la base pre-impuestos (ej. 230.47 - 59 = 171.47), valor
  /// que no cuadra con el SUBTOTAL recomputado (236/1.28 = 184.38). Fuera de
  /// ese caso (exclusive, tasas mixtas o sin tasa) usamos la base nativa.
  static double _printableItemBaseTotal(
    Order? order,
    OrderItem item, {
    required bool canRecompute,
    required bool isPostDiscountMode,
    required double declaredRate,
  }) {
    if (canRecompute && item.taxMode == 'inclusive' && declaredRate > 0) {
      // itemDisplayTotal (inclusive) = gross catálogo - descuento.
      final grossAfterDiscount = itemDisplayTotal(order, item);
      final gross = isPostDiscountMode
          ? grossAfterDiscount
          : grossAfterDiscount + item.discounts;
      return gross / (1 + declaredRate);
    }
    return itemDisplayBaseTotal(order, item);
  }

  /// Detección de tasa uniforme + modo de descuento, compartida entre la
  /// línea por ítem y el bloque de totales para que ambos usen exactamente
  /// el mismo criterio de recomputación.
  static _RecomputeContext _resolveRecomputeContext({
    required double subtotal,
    required double tax,
    required double serviceFee,
    required List<({String label, double amount})> taxBreakdown,
    required String discountDisplayMode,
  }) {
    final isPostDiscountMode = discountDisplayMode == 'post_discount';
    final lineRates = <double?>[];
    for (final entry in taxBreakdown) {
      lineRates.add(_parseInvoiceRatePercent(entry.label));
    }
    final allRatesKnown =
        taxBreakdown.isNotEmpty && !lineRates.contains(null);
    final declaredRate = allRatesKnown
        ? lineRates.fold<double>(0, (s, r) => s + (r ?? 0)) / 100.0
        : 0.0;
    final actualRate =
        subtotal > 0.005 ? (tax + serviceFee) / subtotal : 0.0;
    final ratesAreUniform = (actualRate - declaredRate).abs() < 0.001;
    final canRecompute =
        allRatesKnown && declaredRate > 0 && ratesAreUniform;
    return _RecomputeContext(
      isPostDiscountMode: isPostDiscountMode,
      lineRates: lineRates,
      declaredRate: declaredRate,
      canRecompute: canRecompute,
    );
  }

  static _PrintableReceiptTotals _resolvePrintableTotals({
    required Order order,
    required Iterable<OrderItem> items,
    bool preferStoredOrderTotals = false,
  }) {
    final summary = summarizeOrderPricing(order, items);
    final hasStoredTotals =
        order.subtotal > 0 ||
        order.tax > 0 ||
        order.serviceFee > 0 ||
        order.total > 0 ||
        order.discounts > 0;

    // Preferimos `summary` (incluye recomputación takeout-inclusive y la
    // override `inclusiveGrossNet` → matchea la UI). Caemos a los valores
    // guardados en DB SOLO cuando `summary` está degenerado (perdió la info
    // de impuestos pero la orden persistida sí los tiene). Esto hace que
    // reimpresiones (con `preferStoredOrderTotals=true`) usen la lógica
    // recomputada y no los valores antiguos del trigger backend, que para
    // takeout inclusive sobreestimaba el ITBIS y subestimaba el subtotal.
    final summaryIsDegenerate = summary.tax <= 0 && order.tax > 0;

    // Reimpresión de comprobantes ya emitidos (`preferStoredOrderTotals`):
    // el NCF manda. Si el total recomputado desde ítems difiere del total
    // GUARDADO en el comprobante por más de RD$1, imprimimos los valores
    // oficiales del fiscal document (subtotal/impuestos/total) en vez del
    // recálculo. Pasa cuando la orden se cerró con un monto distinto al de
    // sus ítems (ej. cobro que no cubrió todo, o ítems editados tras emitir):
    // el papel debe coincidir con la pantalla y con lo que registró la DGII,
    // no inflar/desinflar según los ítems. Igual que el guard del modal en
    // sales_history_view. Gate estricto (flag + total guardado > 0 +
    // desajuste real) → facturas en vivo y reimpresiones que cuadran NO se
    // ven afectadas.
    final mismatchVsStored =
        preferStoredOrderTotals &&
        hasStoredTotals &&
        order.total > 0 &&
        (summary.total - order.total).abs() > 1.0;

    final useStoredTotals =
        (hasStoredTotals && summaryIsDegenerate) || mismatchVsStored;

    if (!useStoredTotals) {
      return _PrintableReceiptTotals(
        subtotal: summary.subtotal,
        discounts: summary.discounts,
        serviceFee: summary.serviceFee,
        tax: summary.tax,
        total: summary.total,
        deliveryFee: summary.deliveryFee,
      );
    }

    return _PrintableReceiptTotals(
      subtotal: order.subtotal,
      discounts: order.discounts,
      serviceFee: order.serviceFee,
      tax: order.tax,
      total: order.total,
      deliveryFee: order.deliveryFee,
    );
  }

  /// ============================================================
  /// COMANDA DE COCINA
  /// ============================================================
  ///
  /// Diseño: header con CAJERO; titulo "COMANDA / DE <AREA>"; bloque
  /// 2 columnas (ORDEN/MESA, MESERO/HORA, FECHA); items en cards
  /// separadas por dashed; recuadro inverse "PARA LLEVAR" si aplica;
  /// footer dashed con timestamp + cajero.
  ///
  /// [areaCode] controla el subtitulo (DE COCINA / DE BAR / DE CAJA).
  /// [cashierName] aparece en header y footer; si null, se omiten.
  static PrintTicket generateKitchenTicket({
    required Order order,
    required List<OrderItem> items,
    required String tableName,
    String? waiterName,
    String? cashierName,
    String? customerName,
    String? businessName, // ya no se usa en el nuevo diseño, se ignora.
    String? areaCode,
    bool isReprint = false,
    String receiptItemDisplayMode = 'grouped',
    /// Flags de franjas (banners inversos) por sección. Cada uno
    /// controla si SU sección lleva la franja arriba:
    ///   - [showDineInBanner]  → franja "PARA COMER AQUI" para items dine-in.
    ///   - [showTakeoutBanner] → franja "PARA LLEVAR" para items takeout.
    /// Los items siempre se separan por isTakeout; los flags solo
    /// deciden si cada sección imprime su banner. Default: ambos true
    /// (comportamiento histórico).
    bool showDineInBanner = true,
    bool showTakeoutBanner = true,
  }) {
    final gen = EscPosGenerator(paperWidth: 80);
    final printableItems = _buildPrintableItems(
      items,
      receiptItemDisplayMode: receiptItemDisplayMode,
    );

    // Particionar por isTakeout. Mantener orden relativo dentro de cada
    // grupo igual al orden original. Cuando el sectionMode fuerza una
    // sola franja, las listas regular/takeout se ignoran y se usa una
    // única lista combinada bajo el label correspondiente.
    final regularItems = printableItems.where((i) => !i.isTakeout).toList();
    final takeoutItems = printableItems.where((i) => i.isTakeout).toList();

    gen.initialize();
    // Double-strike para la comanda: imprime cada línea 2 veces — texto
    // mas nítido/oscuro y la mecánica avanza más lento (calidad > velocidad
    // para que cocina lea sin esfuerzo).
    gen.setDoubleStrike(true);

    final resolvedCashier = cashierName?.trim();

    // ─── TITULO en una sola linea ───────────────────────────────────
    // "COMANDA DE COCINA" (17ch) en width:2 height:2 bold. A 2x width el
    // line max es 24ch — entra holgado y se ve proporcional (no estirado
    // como 1x2).
    final (titleMain, titleSub) = _kitchenTitleParts(areaCode);
    final titleSingle = isReprint ? 'REIMPRESIÓN' : '$titleMain $titleSub';
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(titleSingle);
    gen.setBold(false);
    gen.setTextSize();
    gen.doubleSeparator();

    // ─── INFO DE ORDEN en 2 columnas ────────────────────────────────
    // Sin linefeed entre filas: las labels (ORDEN/MESA, MESERO/HORA)
    // y sus valores quedan apilados directamente para un look mas
    // compacto.
    gen.textRow('ORDEN', 'MESA');
    gen.setBold(true);
    gen.textRow(
      '#${order.id.substring(0, 8).toUpperCase()}',
      tableName.isNotEmpty ? tableName : '-',
    );
    gen.setBold(false);

    if ((waiterName != null && waiterName.isNotEmpty) ||
        order.createdAt.year > 1970) {
      gen.textRow('MESERO', 'HORA');
      gen.setBold(true);
      gen.textRow(
        (waiterName?.isNotEmpty ?? false) ? waiterName! : '-',
        _formatTime(order.createdAt),
      );
      gen.setBold(false);
    }

    gen.text(_formatDate(order.createdAt));
    // CAJERO baja al bloque de datos de orden (antes estaba en el top
    // separado). Queda como linea propia abajo de la fecha.
    if (resolvedCashier != null && resolvedCashier.isNotEmpty) {
      gen.text('CAJERO: ${resolvedCashier.toUpperCase()}');
    }
    // CLIENTE: nombre que el mesero capturó al abrir la mesa
    // (table_sessions.customer_name). Línea propia debajo de cajero
    // para que cocina identifique el comensal de un vistazo. Se omite
    // si la mesa no tiene cliente asignado (caso típico walk-in sin
    // registro previo).
    final resolvedCustomer = customerName?.trim();
    if (resolvedCustomer != null && resolvedCustomer.isNotEmpty) {
      gen.setBold(true);
      gen.text('CLIENTE: ${resolvedCustomer.toUpperCase()}');
      gen.setBold(false);
    }
    gen.doubleSeparator();

    // ─── BLOQUES DE FRANJAS ─────────────────────────────────────────
    // Los items siempre se separan por isTakeout. Cada flag decide si
    // SU sección lleva la franja inversa arriba:
    //   showDineInBanner=true,  showTakeoutBanner=true  → ambas franjas (legacy).
    //   showDineInBanner=true,  showTakeoutBanner=false → solo franja dine-in.
    //   showDineInBanner=false, showTakeoutBanner=true  → solo franja takeout.
    //   showDineInBanner=false, showTakeoutBanner=false → todo pelado.
    if (regularItems.isNotEmpty) {
      _renderItemsList(
        gen,
        label: 'PARA COMER AQUI',
        items: regularItems,
        showBanner: showDineInBanner,
      );
    }
    if (takeoutItems.isNotEmpty) {
      _renderItemsList(
        gen,
        label: 'PARA LLEVAR',
        items: takeoutItems,
        showBanner: showTakeoutBanner,
      );
    }

    // ─── FOOTER ─────────────────────────────────────────────────────
    // Sin separador propio: el `doubleSeparator` que cierra el último
    // bloque de items ya provee la división visual con el footer.
    gen.lineFeed();
    final now = DateTime.now();
    final hms =
        '${_formatTime(now)}:${now.second.toString().padLeft(2, '0')}';
    gen.textCentered(
      resolvedCashier != null && resolvedCashier.isNotEmpty
          ? '$hms · $resolvedCashier'
          : hms,
    );

    // 1 linefeed antes del cut: suficiente margen para que el cutter
    // no toque el footer pero sin desperdiciar papel.
    gen.lineFeed();
    gen.cut();

    return PrintTicket(
      type: 'kitchen_order',
      escPosCommands: gen.getCommands(),
    );
  }

  /// Separador entre items. Linea solida `-----` en lugar de dashed
  /// disperso `- - - -` para que se imprima nitida en termicas
  /// economicas. Sin linefeed extra — el wrapping de los items ya
  /// deja el espaciado correcto.
  static void _kitchenDashedSeparator(EscPosGenerator gen) {
    gen.text('-' * 48);
  }

  /// Mapea un areaCode a su titulo de comanda. Casos especiales que la
  /// app distingue hoy: kitchen_hot/kitchen_cold/kitchen → "COCINA";
  /// bar → "BAR"; cashier → "CAJA"; fiscal → "CAJA". Cualquier otro
  /// codigo (custom: "pizza", "sushi", etc) se uppercase y se inserta
  /// como esta.
  /// Devuelve (titulo grande, subtitulo) para imprimir en 2 lineas.
  /// kitchen* → ("COMANDA", "DE COCINA"); bar → ("COMANDA", "DE BAR");
  /// cashier/fiscal → ("COMANDA", "DE CAJA"); custom → ("COMANDA", "DE
  /// CUSTOM_AREA").
  static (String, String) _kitchenTitleParts(String? areaCode) {
    final code = (areaCode ?? '').trim().toLowerCase();
    if (code.isEmpty || code.startsWith('kitchen')) {
      return ('COMANDA', 'DE COCINA');
    }
    if (code == 'bar') return ('COMANDA', 'DE BAR');
    if (code == 'cashier' || code == 'fiscal') {
      return ('COMANDA', 'DE CAJA');
    }
    return ('COMANDA', 'DE ${code.replaceAll('_', ' ').toUpperCase()}');
  }

  /// Renderiza items bajo una **banda inversa full-ancho** con el label
  /// centrado en `width:2 height:2` (`GS B 1` blanco-sobre-negro). Items
  /// también en 2x2 bold — mismo "tipo de texto" que el label, lo único
  /// que los diferencia es el fondo invertido. Modificadores/notas
  /// indentados a tamaño normal, separador thin entre items con aire
  /// vertical, y `doubleSeparator` (`===`) cerrando la sección.
  ///
  /// [showBanner] permite renderizar solo los items, sin la franja
  /// inversa — usado por el modo `takeout_banner_only` para emitir los
  /// items dine-in "pelados" antes del banner de takeout.
  static void _renderItemsList(
    EscPosGenerator gen, {
    required String label,
    required List<OrderItem> items,
    bool showBanner = true,
  }) {
    if (showBanner) {
      // Banda inversa 2x2: padding a 24 chars (line max a width:2). El
      // padding hace que el fondo negro se extienda full-ancho. Sin
      // padding solo se invertiria sobre los chars del label dando una
      // banda flaca.
      gen.setInverse(true);
      gen.setTextSize(width: 2, height: 2);
      gen.setBold(true);
      gen.text(_centerInWidth(label.toUpperCase(), 24));
      gen.setBold(false);
      gen.setTextSize();
      gen.setInverse(false);
      gen.lineFeed();
    }

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final qty = _formatQty(item.quantity);

      // Items en width:2 height:2 (proporcional, no estirado como 1x2).
      // Wrap width 24 (line max a 2x).
      gen.setTextSize(width: 2, height: 2);
      gen.setBold(true);
      _writeWrappedLine(gen, '$qty  ${item.productName}', 24);
      gen.setBold(false);
      gen.setTextSize();

      if (item.modifiers.isNotEmpty) {
        for (final mod in item.modifiers) {
          final isComboChoice = mod.name.contains(': ');
          // Costo total que suma este modifier a la línea (alineado con
          // catalogGrossAmount): qty_item × qty_modifier × precio_unitario.
          final itemQty = item.quantity <= 0 ? 1.0 : item.quantity;
          final modTotal = mod.price * itemQty * mod.qty;
          final priceSuffix = modTotal > 0
              ? ' (+${_formatMoney(modTotal)})'
              : '';
          final prefix = isComboChoice ? '   • ' : '   + ';
          _writeWrappedLine(gen, '$prefix${mod.name}$priceSuffix', 48);
        }
      }

      final cleanNote = cleanOrderItemNote(item.notes);
      if (cleanNote.isNotEmpty) {
        gen.setBold(true);
        _writeWrappedLine(gen, '   NOTA: $cleanNote', 48);
        gen.setBold(false);
      }

      // Separador thin entre items con aire vertical antes/después
      // (no después del último: ahí cierra el doubleSeparator).
      if (i < items.length - 1) {
        gen.lineFeed();
        _kitchenDashedSeparator(gen);
        gen.lineFeed();
      }
    }

    // Cierre de sección con doble separador thick + aire arriba.
    gen.lineFeed();
    gen.doubleSeparator();
  }

  /// Padea [text] con espacios laterales para centrarlo en una línea de
  /// [width] chars. Necesario cuando un fondo (e.g. inverse video) debe
  /// extenderse full-ancho con el texto centrado adentro.
  static String _centerInWidth(String text, int width) {
    if (text.length >= width) return text.substring(0, width);
    final pad = (width - text.length) ~/ 2;
    final right = width - pad - text.length;
    return '${' ' * pad}$text${' ' * right}';
  }

  /// Word-wrap por espacios. Escribe cada linea via `gen.text` directamente.
  static void _writeWrappedLine(EscPosGenerator gen, String text, int width) {
    if (text.length <= width) {
      gen.text(text);
      return;
    }
    final words = text.split(' ');
    var current = '';
    for (final w in words) {
      final candidate = current.isEmpty ? w : '$current $w';
      if (candidate.length <= width) {
        current = candidate;
      } else {
        if (current.isNotEmpty) gen.text(current);
        current = w;
      }
    }
    if (current.isNotEmpty) gen.text(current);
  }

  /// ============================================================
  /// PRECUENTA - DISEÑO TÉRMICO MEJORADO
  /// ============================================================
  static PrintTicket generatePrecheck({
    required Order order,
    required List<OrderItem> items,
    required String tableName,
    String? waiterName,
    String? customerName,
    String? businessName,
    String? legalName,
    String? businessAddress,
    String? businessPhone,
    String? businessRnc,
    // PRD 6: settings de moneda secundaria USD. Si está null o
    // `enabled = false`, no se imprime nada relacionado a USD.
    UsdDisplaySettings? usdSettings,
    String title = 'PRECUENTA',
    String receiptItemDisplayMode = 'grouped',
    List<({String label, double amount})> taxBreakdown = const [],
    /// Branding compartido con la factura (mismas listas de bloques).
    List<int>? logoBytes,
    String? slogan,
    String? branchName,
    String? businessEmail,
    String? footerMessage,
    List<TicketBlock>? headerBlocks,
    List<TicketBlock>? footerBlocks,
    /// Modo de presentación del descuento. Ver `generateInvoice` para
    /// la semántica completa de `'pre_discount'` vs `'post_discount'`.
    /// Default `'pre_discount'` (comportamiento histórico).
    String discountDisplayMode = 'pre_discount',
    /// Modelo de impresión (mismo setting `invoice_print_template` que la
    /// factura): 'standard', 'compact' (1 línea + blanco) o 'simple' (estilo
    /// KAELUS: "# N:" con líneas seguidas). La pre-cuenta sigue el modo elegido.
    String template = 'standard',
    /// Moneda base del negocio. Default DOP preserva el formato `RD$` legacy.
    BusinessCurrency? currency,
  }) {
    _currency = currency ?? BusinessCurrency.fallbackDop;
    final gen = EscPosGenerator(paperWidth: 80);
    final consolidatedItems = _buildPrintableItems(
      items,
      receiptItemDisplayMode: receiptItemDisplayMode,
    );
    final compact = template != 'standard';
    final simple = template == 'simple';

    gen.initialize();

    // En compacto se omiten los saltos en blanco decorativos (los separadores
    // se conservan) para que la pre-cuenta salga tan apretada como la factura.
    void gap([int n = 1]) {
      if (!compact) gen.lineFeed(n);
    }

    gen.lineFeed(compact ? 1 : 2);

    // ════════════════════════════════════════════
    // HEADER (mismo orden/visibilidad que la factura)
    // ════════════════════════════════════════════
    _renderHeaderBlocks(
      gen,
      blocks: headerBlocks ?? TicketBlocks.defaultHeader,
      logoBytes: logoBytes,
      businessName: businessName,
      slogan: slogan,
      legalName: legalName,
      branchName: branchName,
      address: businessAddress,
      phone: businessPhone,
      email: businessEmail,
      rnc: businessRnc,
    );

    if (!compact) {
      gen.lineFeed();
      _thinSeparator(gen);
      gen.lineFeed();
    }

    // ════════════════════════════════════════════
    // TÍTULO DEL DOCUMENTO (en compacto sin asteriscos: "*** X ***" → "X")
    // ════════════════════════════════════════════
    final displayTitle = compact ? title.replaceAll('*', '').trim() : title;
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(displayTitle);
    gen.setBold(false);
    gen.setTextSize();

    gap();
    _thickSeparator(gen);
    gap();

    // ════════════════════════════════════════════
    // INFORMACIÓN DE LA ORDEN
    // ════════════════════════════════════════════
    gen.setBold(true);
    gen.textRow('ORDEN:', order.id.substring(0, 8).toUpperCase());
    gen.setBold(false);

    if (tableName.isNotEmpty) {
      gen.textRow('MESA:', tableName);
    }

    // Separar fecha y hora en líneas diferentes
    final dateStr = _formatDate(order.createdAt);
    final timeStr = _formatTime(order.createdAt);
    gen.textRow('FECHA:', dateStr);
    gen.textRow('HORA:', timeStr);

    if (waiterName != null && waiterName.isNotEmpty) {
      gen.textRow('MESERO:', waiterName);
    }

    // Nombre del cliente cuando esté disponible (capturado al abrir la
    // mesa o asignado en el modal de cobro). Va después de MESERO para
    // mantener el orden visual de la precuenta en pantalla.
    final trimmedCustomer = customerName?.trim();
    if (trimmedCustomer != null && trimmedCustomer.isNotEmpty) {
      gen.textRow('CLIENTE:', trimmedCustomer);
    }

    gap();
    _thinSeparator(gen);

    // ════════════════════════════════════════════
    // ITEMS - PRODUCTOS (SIN QTY)
    // ════════════════════════════════════════════
    if (!simple) {
      gen.setBold(true);
      gen.textRow(
        compact ? 'Cant. Descripción' : 'DESCRIPCIÓN',
        compact ? 'Precio' : 'TOTAL',
      );
      gen.setBold(false);
      _thinSeparator(gen);
    }
    gap(); // línea en blanco debajo del encabezado

    // Criterio de recomputación (tasa uniforme + modo de descuento). Se
    // calcula ANTES del loop para que la base por línea y el SUBTOTAL de los
    // totales usen exactamente la misma fórmula y cuadren al centavo.
    final printableSummary = summarizeOrderPricing(order, items);
    final recompute = _resolveRecomputeContext(
      subtotal: printableSummary.subtotal,
      tax: printableSummary.tax,
      serviceFee: printableSummary.serviceFee,
      taxBreakdown: taxBreakdown,
      discountDisplayMode: discountDisplayMode,
    );

    for (int i = 0; i < consolidatedItems.length; i++) {
      final item = consolidatedItems[i];
      // Layout B: la línea principal muestra el PRECIO BASE del producto
      // (sin sumar modificadores). El modifier sale en su propia línea con
      // su delta, y el total de la derecha (`baseTotal`) ya incluye base +
      // modifiers para que cuadre con SUBTOTAL.
      final baseUnitPrice = item.unitPrice;

      // Impuestos por item: NO se muestran aquí (solo consolidados en TOTALES);
      // el snapshot en `order_item_tax_lines` se mantiene para la factura.
      final displayQty = _formatQty(item.quantity);
      final cleanNote = cleanOrderItemNote(item.notes);
      final baseTotal = _printableItemBaseTotal(
        order,
        item,
        canRecompute: recompute.canRecompute,
        isPostDiscountMode: recompute.isPostDiscountMode,
        declaredRate: recompute.declaredRate,
      );

      if (compact && simple) {
        // v3 SIMPLE (estilo KAELUS): "# N: Nombre qty X precio …… total",
        // líneas SEGUIDAS (sin blanco), modificadores con precio.
        gen.dotRow(
          '# ${i + 1}: ${item.productName} $displayQty X ${_formatMoney(baseUnitPrice)}',
          _formatMoney(baseTotal),
        );
        if (item.isTakeout) {
          gen.setBold(true);
          gen.text('   [PARA LLEVAR]');
          gen.setBold(false);
        }
        for (final mod in item.modifiers) {
          final itemQty = item.quantity <= 0 ? 1.0 : item.quantity;
          final modTotal = mod.price * itemQty * mod.qty;
          gen.dotRow(
            '   Modificador: ${mod.name}',
            _formatMoney(modTotal),
          );
        }
        if (cleanNote.isNotEmpty) {
          gen.text('   NOTA: $cleanNote');
        }
        // Líneas seguidas: sin renglón en blanco entre ítems.
      } else if (compact) {
        // Una sola línea: "1x Nombre …………… total" (sin "#"). Modificadores
        // (con precio) y nota indentados debajo; un renglón en blanco separa
        // cada ítem.
        gen.dotRow(
          '${displayQty}x ${item.productName}',
          _formatMoney(baseTotal),
        );
        if (item.isTakeout) {
          gen.setBold(true);
          gen.text('   [PARA LLEVAR]');
          gen.setBold(false);
        }
        for (final mod in item.modifiers) {
          final itemQty = item.quantity <= 0 ? 1.0 : item.quantity;
          final modTotal = mod.price * itemQty * mod.qty;
          gen.dotRow(
            '   Modificador: ${mod.name}',
            _formatMoney(modTotal),
          );
        }
        if (cleanNote.isNotEmpty) {
          gen.text('   NOTA: $cleanNote');
        }
        gen.lineFeed(); // espacio entre ítems
      } else {
        // Nombre del producto en negrita
        gen.setBold(true);
        gen.text(item.productName);
        gen.setBold(false);

        // Cantidad x precio unitario base ......... TOTAL CON MODIFICADORES
        final leftPart = '$displayQty x ${_formatMoney(baseUnitPrice)}';
        final rightPart = _formatMoney(baseTotal);
        gen.dotRow(leftPart, rightPart);

        // Indicador para llevar (takeout)
        if (item.isTakeout) {
          gen.setBold(true);
          gen.text('  [PARA LLEVAR]');
          gen.setBold(false);
        }

        // Modificadores con indentación
        if (item.modifiers.isNotEmpty) {
          for (final mod in item.modifiers) {
            final itemQty = item.quantity <= 0 ? 1.0 : item.quantity;
            final modTotal = mod.price * itemQty * mod.qty;
            final priceSuffix = modTotal > 0
                ? ' (+${_formatMoney(modTotal)})'
                : '';
            gen.text('  + ${mod.name}$priceSuffix');
          }
        }

        // Notas especiales destacadas
        if (cleanNote.isNotEmpty) {
          gen.setBold(true);
          gen.text('  NOTA: $cleanNote');
          gen.setBold(false);
        }

        // Espacio ligero entre items
        if (i < consolidatedItems.length - 1) {
          gen.lineFeed();
        }
      }
    }

    _thinSeparator(gen);

    // ════════════════════════════════════════════
    // TOTALES
    // ════════════════════════════════════════════
    gap();

    // Totales salen de los items ORIGINALES (no consolidados) para que el
    // subtotal absorba el centavo de redondeo por-item y coincida exactamente
    // con lo que ve el cajero en pantalla. Los items consolidados se usan solo
    // para el render de las lineas del ticket. `printableSummary` y el criterio
    // de recompute (`recompute`) ya se calcularon antes del loop de ítems para
    // que la base por línea y este SUBTOTAL usen la misma fórmula.
    final printableDiscounts = printableSummary.discounts;
    final double printableGrandTotal = printableSummary.total;

    // Recomputamos subtotal/impuestos según el modo elegido por el negocio
    // para que la math del precheck siempre cierre visualmente (misma
    // lógica que generateInvoice). Default `pre_discount`. Si las tasas son
    // mixtas o no parseables, `canRecompute` es false y caemos al path legacy.
    final isPostDiscountMode = recompute.isPostDiscountMode;
    final lineRates = recompute.lineRates;
    final declaredRate = recompute.declaredRate;
    final canRecompute = recompute.canRecompute;

    if (canRecompute) {
      final discountForBase = isPostDiscountMode ? 0.0 : printableDiscounts;
      // El fee de delivery es EXENTO: fuera de la base gravable.
      final subtotalBase =
          (printableGrandTotal -
                  printableSummary.deliveryFee +
                  discountForBase) /
              (1 + declaredRate);
      gen.textRow('SUBTOTAL:', _formatMoney(subtotalBase));
      for (var i = 0; i < taxBreakdown.length; i++) {
        final rate = lineRates[i] ?? 0;
        final amount = subtotalBase * (rate / 100);
        if (amount.abs() < 0.005) continue;
        gen.textRow(
          '${taxBreakdown[i].label}:',
          _formatMoney(amount),
        );
      }
      if (!isPostDiscountMode && printableDiscounts > 0) {
        gen.textRow(
          'DESCUENTO:',
          '-${_formatMoney(printableDiscounts)}',
        );
      }
    } else {
      // Fallback legacy (sin tasa parseable o sin tax breakdown).
      final double printableSubtotal = printableSummary.subtotal;
      gen.textRow('SUBTOTAL:', _formatMoney(printableSubtotal));
      if (taxBreakdown.isNotEmpty) {
        for (final entry in taxBreakdown) {
          if (entry.amount.abs() < 0.005) continue;
          gen.textRow(
            '${entry.label}:',
            _formatMoney(entry.amount),
          );
        }
      } else {
        final printableTax = printableSummary.tax;
        final printableServiceFee = printableSummary.serviceFee;
        if (printableServiceFee > 0) {
          final servicePct = printableSubtotal > 0
              ? ((printableServiceFee / printableSubtotal) * 100)
                    .toStringAsFixed(0)
              : '0';
          gen.textRow(
            'SERVICIO ($servicePct%):',
            _formatMoney(printableServiceFee),
          );
        }
        if (printableTax > 0.005) {
          gen.textRow('ITBIS:', _formatMoney(printableTax));
        }
      }
      if (printableDiscounts > 0) {
        gen.textRow(
          'DESCUENTO:',
          '-${_formatMoney(printableDiscounts)}',
        );
      }
    }

    // Post-discount mode: el descuento se muestra como línea informativa
    // justo debajo de los impuestos (no sustractiva: el total ya lo incluye).
    if (canRecompute && isPostDiscountMode && printableDiscounts > 0) {
      gen.textRow('Descuento :', _formatMoney(printableDiscounts));
    }

    // Fee de delivery propio: cargo exento, parte del total.
    if (printableSummary.deliveryFee > 0) {
      gen.textRow('DELIVERY:', _formatMoney(printableSummary.deliveryFee));
    }

    gap();
    _thickSeparator(gen);
    gap();

    // ════════════════════════════════════════════
    // TOTAL FINAL - Tamaño grande
    // ════════════════════════════════════════════
    if (compact) gen.lineFeed(); // espacio (reducido) arriba del TOTAL
    gen.setBold(true);
    gen.setTextSize(width: 2, height: 2);
    gen.textRow('TOTAL:', _formatMoney(printableGrandTotal));
    gen.setTextSize();
    gen.setBold(false);
    if (compact) gen.lineFeed(); // espacio (reducido) abajo del TOTAL

    // PRD 6: equivalente USD debajo del TOTAL si está activo.
    // Decisión del cliente: la tasa NO sale en ningún ticket (ni
    // pre-cuenta ni factura). El cliente ve solo el equivalente USD
    // como referencia.
    _renderUsdEquivalent(gen, printableGrandTotal, usdSettings, showRate: false);

    // ════════════════════════════════════════════
    // DATOS DE COMPROBANTE FISCAL
    // ════════════════════════════════════════════
    gen.lineFeed();
    gen.text('RNC/CÉDULA: ______________________');
    gen.lineFeed();
    gen.text('RAZÓN SOCIAL: _____________________');
    gen.lineFeed();

    // ════════════════════════════════════════════
    // AVISO DE PRECUENTA
    // ════════════════════════════════════════════
    gen.lineFeed();

    // Caja de aviso
    _thickSeparator(gen);
    gen.setBold(true);
    gen.textCentered('AVISO: ESTE DOCUMENTO ES SOLO');
    gen.textCentered('UNA PRECUENTA');
    gen.setBold(false);

    // ════════════════════════════════════════════
    // FOOTER (mismas listas que la factura)
    // ════════════════════════════════════════════
    gen.lineFeed();
    _renderFooterBlocks(
      gen,
      blocks: footerBlocks ?? TicketBlocks.defaultFooter,
      footerMessage: footerMessage,
    );
    gen.lineFeed();
    // Aviso especifico de pre-cuenta — fijo, no parte de los bloques
    // configurables (es disclaimer, no branding).
    gen.textCentered('Por favor verifique los datos');
    gen.textCentered('antes de proceder al pago');

    gen.lineFeed(compact ? 2 : 4);
    gen.cut();

    return PrintTicket(type: 'precheck', escPosCommands: gen.getCommands());
  }

  /// ============================================================
  /// FACTURA (RECIBO DE PAGO)
  /// ============================================================
  static PrintTicket generateInvoice({
    required Order order,
    required List<OrderItem> items,
    required List<Payment> payments,
    required String tableName,
    String? waiterName,
    String? businessName,
    String? legalName,
    String? businessAddress,
    String? businessPhone,
    String? businessRnc,
    String? fiscalNcf,
    String? fiscalType,
    String? customerName,
    String? customerLegalName,
    String? customerTaxId,
    /// Dirección de entrega (delivery). Si viene non-null/no-vacía se
    /// imprime una línea "DIRECCIÓN:" debajo del cliente. Solo aplica a
    /// pedidos de delivery con dirección capturada.
    String? deliveryAddress,
    DateTime? issuedAt,
    // PRD 6: settings de moneda secundaria USD (mismo patrón que
    // generatePrecheck). Si null o disabled, no imprime nada de USD.
    UsdDisplaySettings? usdSettings,
    String title = 'FACTURA',
    String receiptItemDisplayMode = 'grouped',
    List<({String label, double amount})> taxBreakdown = const [],
    bool preferStoredOrderTotals = false,
    bool preferStoredItemTotals = false,
    /// Bytes ESC/POS pre-generados del QR del e-CF (centrados). Cuando es
    /// non-null se imprimen después de la sección de pagos. Generar con
    /// `QrEscPosBuilder.build(data: fiscalDoc.publicUrl!)`.
    List<int>? qrBytes,
    /// Mensaje de estado del e-CF a imprimir cuando aún no hay QR
    /// (ej. "Pendiente de aprobacion DGII", "Rechazado por DGII: ...").
    /// Solo aplica para e-CF; ignorado en NCF físico.
    String? ecfStatusMessage,
    /// `true` si el documento es e-CF (Exx). Cambia las etiquetas a
    /// formato DGII: "Factura de Consumo Electrónica", "e-NCF:", etc.
    bool isElectronicCf = false,
    /// Código de seguridad alfanumérico DGII (campo `ecf_security_code`).
    /// Se imprime debajo del QR en e-CF aceptados.
    String? ecfSecurityCode,
    /// Fecha de firma digital DGII (campo `ecf_signed_at`).
    /// Se imprime debajo del Código de Seguridad en e-CF aceptados.
    DateTime? ecfSignedAt,
    /// Bytes ESC/POS pre-generados del logo (centrados). Se imprimen al
    /// inicio del header si vienen non-null. Generar con
    /// `LogoEscPosBuilder.build(bytes: <pngOrJpgBytes>)`. El caller decide
    /// si carga o no el logo segun `BusinessProfile.printLogoOnInvoice`
    /// y `BusinessProfile.logoUrl`.
    List<int>? logoBytes,
    /// Eslogan del negocio. Se imprime via el bloque `slogan` del header
    /// (orden controlado por [headerBlocks]).
    String? slogan,
    /// Nombre de la sucursal. Se imprime via el bloque `branch_name`.
    String? branchName,
    /// Email del negocio. Bloque `email`, off por default.
    String? businessEmail,
    /// Mensaje opcional al pie del ticket. Se imprime via el bloque
    /// `footer_message` del footer.
    String? footerMessage,
    /// Lista ordenada + on/off de los bloques del header. Si null usa
    /// [TicketBlocks.defaultHeader] (orden canonico legacy).
    List<TicketBlock>? headerBlocks,
    /// Idem para el footer. Si null usa [TicketBlocks.defaultFooter].
    List<TicketBlock>? footerBlocks,
    /// Mapa opcional `payment.id → BankAccount` para imprimir el banco
    /// destino cuando el pago fue por transferencia. Si no se pasa o
    /// no contiene el id, simplemente se omite la línea — el ticket
    /// sigue funcionando como antes (graceful degradation).
    Map<String, BankAccount>? bankAccountsByPaymentId,
    /// Modo de presentación del descuento en el bloque de totales del
    /// ticket. `'pre_discount'` (default, comportamiento histórico):
    /// subtotal pre-descuento, ITBIS al % real, descuento como línea
    /// sustractiva. `'post_discount'`: subtotal y ITBIS derivados del
    /// total post-descuento, descuento se imprime como nota informativa
    /// debajo del TOTAL. Match exacto con el modal del historial cuando
    /// ambos leen el mismo `business_settings.discount_display_mode`.
    String discountDisplayMode = 'pre_discount',
    /// Si `true`, después del corte de papel se apenda el comando
    /// ESC/POS de apertura de gaveta (`ESC p 0 25 250`). El caller debe
    /// pasar `true` solo cuando el método de pago fue efectivo Y el
    /// business tiene `open_drawer_on_cash = true`. Si la impresora no
    /// tiene gaveta RJ-11 conectada, el comando se ignora silenciosamente.
    bool openCashDrawer = false,
    /// Modelo de impresión: 'standard' (detallado, espaciado amplio),
    /// 'compact' (1 línea por ítem "1x Nombre …… precio" + renglón en blanco
    /// entre ítems) o 'simple' (estilo KAELUS: "# N: Nombre qty X precio ……
    /// total" con líneas seguidas, sin blanco). Las tres conservan TODOS los
    /// datos fiscales (NCF/e-NCF, RNC, desglose de impuestos, QR).
    String template = 'standard',
    /// Moneda base del negocio. Default DOP preserva el formato `RD$` legacy.
    BusinessCurrency? currency,
  }) {
    _currency = currency ?? BusinessCurrency.fallbackDop;
    final gen = EscPosGenerator(paperWidth: 80);
    // `compact` = familia de layout apretado (compact + simple): sin
    // asteriscos, espaciado mínimo, TOTAL con poco aire. `simple` además usa
    // el formato de ítem "# N:" con líneas seguidas (sin blanco entre ítems).
    final compact = template != 'standard';
    final simple = template == 'simple';

    gen.initialize();

    // En el modelo compacto, los saltos en blanco puramente decorativos se
    // omiten (las líneas separadoras se conservan, pero sin espacio alrededor)
    // para que el ticket salga tan apretado como un recibo simple.
    void gap([int n = 1]) {
      if (!compact) gen.lineFeed(n);
    }

    gen.lineFeed(compact ? 1 : 2);

    _renderHeaderBlocks(
      gen,
      blocks: headerBlocks ?? TicketBlocks.defaultHeader,
      logoBytes: logoBytes,
      businessName: businessName,
      slogan: slogan,
      legalName: legalName,
      branchName: branchName,
      address: businessAddress,
      phone: businessPhone,
      email: businessEmail,
      rnc: businessRnc,
    );

    if (!compact) {
      gen.lineFeed();
      _thinSeparator(gen);
      gen.lineFeed();
    }

    // Title. En compacto quitamos los asteriscos decorativos del título
    // ("*** FACTURA ***" → "FACTURA").
    final displayTitle = compact ? title.replaceAll('*', '').trim() : title;
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(displayTitle);
    gen.setBold(false);
    gen.setTextSize();

    gap();
    _thickSeparator(gen);
    gap();

    // Bloque del comprobante fiscal:
    // - e-CF (Exx): VA PRIMERO (estandar DGII Norma General 01-2020).
    //   Titulo descriptivo centrado en negrita + "e-NCF:" + separador.
    //   Despues va el ORDEN como dato interno secundario.
    // - NCF fisico (Bxx): TIPO/NCF van DESPUES del ORDEN (formato tradicional).
    if (isElectronicCf &&
        fiscalNcf != null &&
        fiscalNcf.isNotEmpty &&
        fiscalType != null) {
      gen.setBold(true);
      gen.textCentered(_getNcfTypeName(fiscalType));
      gen.textRow('e-NCF:', fiscalNcf);
      gen.setBold(false);
      // Sin lineFeed extra: ORDEN queda inmediatamente debajo de e-NCF, con
      // el mismo espaciado que el resto de filas de datos (MESA, FECHA...).
    }

    // Order Info
    gen.setBold(true);
    gen.textRow('ORDEN:', order.id.substring(0, 8).toUpperCase());
    gen.setBold(false);

    // Para NCF fisico, TIPO/NCF van DESPUES de ORDEN (orden tradicional).
    if (!isElectronicCf) {
      if (fiscalNcf != null && fiscalNcf.isNotEmpty) {
        if (fiscalType != null) {
          gen.textRow('TIPO:', _getNcfTypeName(fiscalType));
        }
        gen.textRow('NCF:', fiscalNcf);
      } else if (fiscalType != null) {
        gen.textRow('TIPO:', _getNcfTypeName(fiscalType));
      }
    }

    if (customerName != null && customerName != 'Cliente') {
      gen.textRow('CLIENTE:', customerName.toUpperCase());
    }
    if (customerLegalName != null &&
        customerLegalName.isNotEmpty &&
        customerLegalName != customerName) {
      gen.textRow('RAZÓN SOCIAL:', customerLegalName.toUpperCase());
    }
    if (customerTaxId != null && customerTaxId.isNotEmpty) {
      gen.textRow('RNC/CÉDULA:', customerTaxId);
    }

    // Dirección de entrega (delivery). Puede ser larga → etiqueta + valor
    // envuelto a ancho de papel (mismo patrón que las notas de item).
    if (deliveryAddress != null && deliveryAddress.trim().isNotEmpty) {
      _writeWrappedLine(gen, 'DIRECCIÓN: ${deliveryAddress.trim()}', 48);
    }

    if (tableName.isNotEmpty) {
      gen.textRow('MESA:', tableName);
    }

    final effectiveIssuedAt = issuedAt ?? DateTime.now();
    final dateStr = _formatDate(effectiveIssuedAt);
    final timeStr = _formatTime(effectiveIssuedAt);
    gen.textRow('FECHA:', dateStr);
    gen.textRow('HORA:', timeStr);

    if (waiterName != null && waiterName.isNotEmpty) {
      gen.textRow('MESERO:', waiterName);
    }

    gap();
    _thinSeparator(gen);

    // Items
    if (!simple) {
      gen.setBold(true);
      gen.textRow(
        compact ? 'Cant. Descripción' : 'DESCRIPCIÓN',
        compact ? 'Precio' : 'TOTAL',
      );
      gen.setBold(false);
      _thinSeparator(gen);
    }
    gap();

    final consolidatedItems = _buildPrintableItems(
      items,
      receiptItemDisplayMode: receiptItemDisplayMode,
    );

    // Totales + criterio de recompute calculados ANTES del loop para que la
    // base por línea y el SUBTOTAL del bloque de totales usen la misma fórmula
    // y cuadren al centavo (ver `_printableItemBaseTotal`).
    final effectiveTotals = _resolvePrintableTotals(
      order: order,
      items: items,
      preferStoredOrderTotals: preferStoredOrderTotals,
    );
    final recompute = _resolveRecomputeContext(
      subtotal: effectiveTotals.subtotal,
      tax: effectiveTotals.tax,
      serviceFee: effectiveTotals.serviceFee,
      taxBreakdown: taxBreakdown,
      discountDisplayMode: discountDisplayMode,
    );

    for (int i = 0; i < consolidatedItems.length; i++) {
      final item = consolidatedItems[i];
      final displayQty = _formatQty(item.quantity);
      // Base de la línea consistente con el SUBTOTAL recomputado (en
      // post_discount ya trae el descuento descontado del gross). El precio
      // unitario se deriva de esa base para que `qty x unit ≈ total`.
      final lineTotal = recompute.canRecompute
          ? _printableItemBaseTotal(
              order,
              item,
              canRecompute: recompute.canRecompute,
              isPostDiscountMode: recompute.isPostDiscountMode,
              declaredRate: recompute.declaredRate,
            )
          : _resolvePrintableItemTotal(
              order,
              item,
              preferStoredItemTotals: preferStoredItemTotals,
            );
      final qtyForUnit = item.quantity <= 0 ? 1.0 : item.quantity;
      final unitPrice = recompute.canRecompute
          ? lineTotal / qtyForUnit
          : _resolvePrintableItemUnitPrice(
              order,
              item,
              preferStoredItemTotals: preferStoredItemTotals,
            );
      final cleanNote = cleanOrderItemNote(item.notes);

      if (compact && simple) {
        // v3 SIMPLE (estilo KAELUS): "# N: Nombre qty X precio …… total",
        // líneas SEGUIDAS (sin blanco entre ítems), modificadores con precio.
        gen.dotRow(
          '# ${i + 1}: ${item.productName} $displayQty X ${_formatMoney(unitPrice)}',
          _formatMoney(lineTotal),
        );
        if (item.isTakeout) {
          gen.setBold(true);
          gen.text('   [PARA LLEVAR]');
          gen.setBold(false);
        }
        for (final mod in item.modifiers) {
          final itemQty = item.quantity <= 0 ? 1.0 : item.quantity;
          final modTotal = mod.price * itemQty * mod.qty;
          gen.dotRow(
            '   Modificador: ${mod.name}',
            _formatMoney(modTotal),
          );
        }
        if (cleanNote.isNotEmpty) {
          gen.text('   NOTA: $cleanNote');
        }
        // Líneas seguidas: sin renglón en blanco entre ítems.
      } else if (compact) {
        // Una sola línea: "1x Nombre …………… total" (sin "#"). Los
        // modificadores (con precio) y la nota van indentados debajo, y un
        // renglón en blanco separa cada ítem.
        gen.dotRow(
          '${displayQty}x ${item.productName}',
          _formatMoney(lineTotal),
        );
        if (item.isTakeout) {
          gen.setBold(true);
          gen.text('   [PARA LLEVAR]');
          gen.setBold(false);
        }
        for (final mod in item.modifiers) {
          final itemQty = item.quantity <= 0 ? 1.0 : item.quantity;
          final modTotal = mod.price * itemQty * mod.qty;
          gen.dotRow(
            '   Modificador: ${mod.name}',
            _formatMoney(modTotal),
          );
        }
        if (cleanNote.isNotEmpty) {
          gen.text('   NOTA: $cleanNote');
        }
        gen.lineFeed(); // espacio entre ítems
      } else {
        gen.setBold(true);
        gen.text(item.productName);
        gen.setBold(false);

        final leftPart = '$displayQty x ${_formatMoney(unitPrice)}';
        final rightPart = _formatMoney(lineTotal);
        gen.dotRow(leftPart, rightPart);

        // Indicador para llevar (takeout)
        if (item.isTakeout) {
          gen.setBold(true);
          gen.text('  [PARA LLEVAR]');
          gen.setBold(false);
        }

        if (item.modifiers.isNotEmpty) {
          for (final mod in item.modifiers) {
            final itemQty = item.quantity <= 0 ? 1.0 : item.quantity;
            final modTotal = mod.price * itemQty * mod.qty;
            final priceSuffix = modTotal > 0
                ? ' (+${_formatMoney(modTotal)})'
                : '';
            gen.text('  + ${mod.name}$priceSuffix');
          }
        }

        if (cleanNote.isNotEmpty) {
          gen.setBold(true);
          gen.text('  NOTA: $cleanNote');
          gen.setBold(false);
        }

        if (i < consolidatedItems.length - 1) {
          gen.lineFeed();
        }
      }
    }

    _thinSeparator(gen);
    gap();

    // Totals
    // Ver comentario en generatePrecheck: usamos los items ORIGINALES para
    // que la absorcion del centavo quede en el subtotal y el papel coincida
    // con la pantalla al centavo. `effectiveTotals` y `recompute` ya se
    // calcularon antes del loop de ítems (misma fórmula que la base por línea).
    final effectiveDiscounts = effectiveTotals.discounts;
    final double effectiveTotal = effectiveTotals.total;

    // Recomputamos subtotal/impuestos según el modo elegido por el negocio
    // para que la math del ticket siempre cierre visualmente.
    //
    //   pre_discount (default):
    //     subtotalBase = (total + descuento) / (1 + tasa)
    //     SUBTOTAL + impuestos − DESCUENTO = TOTAL
    //
    //   post_discount:
    //     subtotalBase = total / (1 + tasa)
    //     SUBTOTAL + impuestos = TOTAL; descuento como nota informativa.
    //
    // Si las tasas son mixtas o no parseables, `canRecompute` es false y
    // caemos al path legacy (valores nativos del summary).
    final isPostDiscountMode = recompute.isPostDiscountMode;
    final lineRates = recompute.lineRates;
    final declaredRate = recompute.declaredRate;
    final canRecompute = recompute.canRecompute;

    // Etiquetas DGII para e-CF (Norma General 01-2020):
    // - "Subtotal Gravado" en lugar de "SUBTOTAL"
    // - "Total ITBIS" en lugar de "ITBIS (18%)"
    final subtotalLabel = isElectronicCf ? 'Subtotal Gravado:' : 'SUBTOTAL:';

    if (canRecompute) {
      final discountForBase = isPostDiscountMode ? 0.0 : effectiveDiscounts;
      // El fee de delivery es EXENTO: fuera de la base gravable.
      final subtotalBase =
          (effectiveTotal - effectiveTotals.deliveryFee + discountForBase) /
          (1 + declaredRate);
      gen.textRow(subtotalLabel, _formatMoney(subtotalBase));
      for (var i = 0; i < taxBreakdown.length; i++) {
        final rate = lineRates[i] ?? 0;
        final amount = subtotalBase * (rate / 100);
        if (amount.abs() < 0.005) continue;
        var label = taxBreakdown[i].label;
        if (isElectronicCf && label.toLowerCase().contains('itbis')) {
          label = 'Total ITBIS';
        }
        gen.textRow('$label:', _formatMoney(amount));
      }
      if (!isPostDiscountMode && effectiveDiscounts > 0) {
        gen.textRow(
          'DESCUENTO:',
          '-${_formatMoney(effectiveDiscounts)}',
        );
      }
    } else {
      // Fallback legacy: imprimimos los valores del summary directo,
      // como antes. Aplica cuando no hay tax_lines parseables.
      final double effectiveSubtotal = effectiveTotals.subtotal;
      gen.textRow(subtotalLabel, _formatMoney(effectiveSubtotal));
      if (taxBreakdown.isNotEmpty) {
        for (final entry in taxBreakdown) {
          if (entry.amount.abs() < 0.005) continue;
          var label = entry.label;
          if (isElectronicCf && label.toLowerCase().contains('itbis')) {
            label = 'Total ITBIS';
          }
          gen.textRow('$label:', _formatMoney(entry.amount));
        }
      } else {
        final effectiveTax = effectiveTotals.tax;
        final effectiveServiceFee = effectiveTotals.serviceFee;
        if (effectiveServiceFee > 0) {
          final servicePct = effectiveSubtotal > 0
              ? ((effectiveServiceFee / effectiveSubtotal) * 100)
                    .toStringAsFixed(0)
              : '0';
          gen.textRow(
            'SERVICIO ($servicePct%):',
            _formatMoney(effectiveServiceFee),
          );
        }
        if (effectiveTax > 0.005) {
          if (isElectronicCf) {
            gen.textRow('Total ITBIS:', _formatMoney(effectiveTax));
          } else {
            final taxPct = effectiveSubtotal > 0
                ? ((effectiveTax / effectiveSubtotal) * 100).toStringAsFixed(0)
                : '18';
            gen.textRow(
              'ITBIS ($taxPct%):',
              _formatMoney(effectiveTax),
            );
          }
        }
      }
      if (effectiveDiscounts > 0) {
        gen.textRow(
          'DESCUENTO:',
          '-${_formatMoney(effectiveDiscounts)}',
        );
      }
    }

    // Post-discount mode: el descuento se muestra como línea informativa
    // justo debajo de los impuestos (no sustractiva: el total ya lo incluye).
    if (canRecompute && isPostDiscountMode && effectiveDiscounts > 0) {
      gen.textRow('Descuento :', _formatMoney(effectiveDiscounts));
    }

    // Fee de delivery propio: cargo exento, parte del total.
    if (effectiveTotals.deliveryFee > 0) {
      gen.textRow('DELIVERY:', _formatMoney(effectiveTotals.deliveryFee));
    }

    gap();
    _thickSeparator(gen);
    gap();

    if (compact) gen.lineFeed(); // espacio (reducido) arriba del TOTAL
    gen.setBold(true);
    gen.setTextSize(width: 2, height: 2);
    gen.textRow('TOTAL:', _formatMoney(effectiveTotal));
    gen.setTextSize();
    gen.setBold(false);
    if (compact) gen.lineFeed(); // espacio (reducido) abajo del TOTAL

    // PRD 6: equivalente USD debajo del TOTAL si toggle está activo.
    // En la factura NO mostramos la tasa (showRate=false): el cliente
    // pagó en DOP, basta con el equivalente USD como referencia. La
    // tasa sí sale en pre-cuenta para transparencia previa al pago.
    _renderUsdEquivalent(gen, effectiveTotal, usdSettings, showRate: false);

    gap();
    _thickSeparator(gen);
    gap();

    // Payments
    if (payments.isNotEmpty) {
      gen.setBold(true);
      gen.text('PAGOS REALIZADOS:');
      gen.setBold(false);

      double totalChange = 0;

      for (final p in payments) {
        final method = _getPaymentMethodName(p);
        gen.textRow(method, _formatMoney(p.amount));
        // Línea adicional cuando es transferencia y tenemos info del
        // banco destino — útil para que el cliente confirme y el
        // contador audite. Indentado 2 espacios para que se note como
        // sub-detalle del pago, no como otro pago.
        final BankAccount? bank;
        if (p.bankAccountId != null && bankAccountsByPaymentId != null) {
          bank = bankAccountsByPaymentId[p.id];
        } else {
          bank = null;
        }
        if (bank != null) {
          final tail = bank.accountTail;
          final holder = (bank.accountHolder ?? '').trim();
          final detail = holder.isEmpty
              ? '  ${bank.bankName} · ····$tail'
              : '  ${bank.bankName} · ····$tail · $holder';
          gen.text(detail);
        }
        totalChange += p.changeAmount;
      }

      if (totalChange > 0) {
        gen.lineFeed();
        gen.setBold(true);
        gen.textRow('CAMBIO:', _formatMoney(totalChange));
        gen.setBold(false);
      }
    }

    // ============================================================
    // QR e-CF (DGII) — debajo de pagos
    // ============================================================
    // Si el e-CF fue aceptado por DGII tenemos public_url codificado en
    // qrBytes. Debajo del QR van Codigo de Seguridad y Fecha de Firma
    // Digital, formato exigido por DGII (ver imagen oficial Norma General).
    // Si está pending/sent/rejected, se muestra el mensaje de estado.
    // Para NCF físico (B0x), todo es no-op.
    if (qrBytes != null && qrBytes.isNotEmpty) {
      gen.lineFeed();
      gen.appendRaw(qrBytes);

      // Codigo de Seguridad + Fecha de Firma Digital, centrados, en negrita.
      // Solo si tenemos los datos (e-CF aceptado vía webhook).
      if ((ecfSecurityCode != null && ecfSecurityCode.isNotEmpty) ||
          ecfSignedAt != null) {
        gen.setAlignment(Alignment.center);
        gen.setBold(true);
        if (ecfSecurityCode != null && ecfSecurityCode.isNotEmpty) {
          gen.text('Código de Seguridad: $ecfSecurityCode');
        }
        if (ecfSignedAt != null) {
          final astSigned = AppTime.astFromInstant(ecfSignedAt);
          final signedDate =
              '${astSigned.day.toString().padLeft(2, '0')}-'
              '${astSigned.month.toString().padLeft(2, '0')}-'
              '${astSigned.year}';
          final signedTime =
              '${astSigned.hour.toString().padLeft(2, '0')}:'
              '${astSigned.minute.toString().padLeft(2, '0')}:'
              '${astSigned.second.toString().padLeft(2, '0')}';
          gen.text('Fecha de Firma Digital: $signedDate $signedTime');
        }
        gen.setBold(false);
        gen.setAlignment(Alignment.left);
      }
    } else if (ecfStatusMessage != null && ecfStatusMessage.isNotEmpty) {
      gen.lineFeed();
      gen.setAlignment(Alignment.center);
      gen.setBold(true);
      gen.text(ecfStatusMessage);
      gen.setBold(false);
      gen.setAlignment(Alignment.left);
    }

    // Footer: bloques en orden segun footerBlocks (o defaults canonicos
    // si null). El renderer skipea bloques sin contenido.
    gen.lineFeed(compact ? 1 : 2);
    _renderFooterBlocks(
      gen,
      blocks: footerBlocks ?? TicketBlocks.defaultFooter,
      footerMessage: footerMessage,
    );
    gen.lineFeed(compact ? 2 : 4);
    gen.cut();
    // Drawer kick va DESPUÉS del corte para que el cajero saque el
    // recibo y la gaveta se abra simultáneamente. Si la impresora no
    // tiene gaveta, el comando se ignora a nivel hardware.
    if (openCashDrawer) {
      gen.openCashDrawer();
    }

    return PrintTicket(type: 'invoice', escPosCommands: gen.getCommands());
  }

  static List<OrderItem> _buildPrintableItems(
    List<OrderItem> items, {
    required String receiptItemDisplayMode,
  }) {
    final normalizedMode = receiptItemDisplayMode.trim().toLowerCase();
    final normalizedItems = _consolidatePrintableItems(items);

    if (normalizedMode == 'separate') {
      return _separatePrintableItems(normalizedItems);
    }
    return normalizedItems;
  }

  static List<OrderItem> _consolidatePrintableItems(List<OrderItem> items) {
    final consolidatedByKey = <String, OrderItem>{};

    for (final item in items) {
      final modifiersKey = item.modifiers
          .map((m) => '${m.name}|${m.qty}|${m.price}')
          .join('~');
      final key =
          '${item.productId ?? ''}|${item.productName}|'
          '${item.sku ?? ''}|${item.unitPrice}|${item.isTakeout}|'
          '${item.status}|${item.notes ?? ''}|$modifiersKey';

      final existing = consolidatedByKey[key];
      if (existing == null) {
        consolidatedByKey[key] = item;
        continue;
      }

      consolidatedByKey[key] = existing.copyWith(
        quantity: existing.quantity + item.quantity,
        subtotal: existing.subtotal + item.subtotal,
        discounts: existing.discounts + item.discounts,
        tax: existing.tax + item.tax,
        total: existing.total + item.total,
        modifiers: _sumMatchingModifiers(existing.modifiers, item.modifiers),
        taxLines: _sumMatchingTaxLines(existing.taxLines, item.taxLines),
      );
    }

    return consolidatedByKey.values.toList(growable: false);
  }

  /// Cuando 2 items con el mismo set de modificadores se fusionan en la
  /// consolidacion, mantenemos los modificadores de uno solo (no sumamos
  /// `qty`). La fmla nueva de `catalogGrossAmount` (qty * (unit + mods))
  /// ya multiplica los modifiers por el qty consolidado del parent, asi
  /// que no hay que pre-amplificarlos aqui.
  static List<OrderItemModifier> _sumMatchingModifiers(
    List<OrderItemModifier> a,
    List<OrderItemModifier> b,
  ) {
    if (a.length != b.length) {
      return [...a, ...b];
    }
    return List<OrderItemModifier>.from(a);
  }

  /// Suma los `amount` de tax lines por `taxId` cuando se consolidan items
  /// duplicados. Necesario para que el desglose por item en la precuenta
  /// muestre el ITBIS/LEY acumulado de las N filas que se fusionaron en una.
  static List<OrderItemTaxLine> _sumMatchingTaxLines(
    List<OrderItemTaxLine> a,
    List<OrderItemTaxLine> b,
  ) {
    if (a.isEmpty) return List<OrderItemTaxLine>.from(b);
    if (b.isEmpty) return List<OrderItemTaxLine>.from(a);

    final byId = <String, OrderItemTaxLine>{};
    for (final line in [...a, ...b]) {
      final existing = byId[line.taxId];
      if (existing == null) {
        byId[line.taxId] = line;
      } else {
        byId[line.taxId] = OrderItemTaxLine(
          id: existing.id,
          orderItemId: existing.orderItemId,
          taxId: existing.taxId,
          taxName: existing.taxName,
          taxRate: existing.taxRate,
          amount: existing.amount + line.amount,
          createdAt: existing.createdAt,
        );
      }
    }
    return byId.values.toList(growable: false);
  }

  static List<OrderItem> _separatePrintableItems(List<OrderItem> items) {
    final separated = <OrderItem>[];

    for (final item in items) {
      final roundedQty = item.quantity.roundToDouble();
      final isWholeQuantity = (item.quantity - roundedQty).abs() < 0.001;

      if (!isWholeQuantity || roundedQty <= 1) {
        separated.add(item);
        continue;
      }

      final parts = roundedQty.toInt();
      final baseSubtotal = item.subtotal / parts;
      final baseDiscount = item.discounts / parts;
      final baseTax = item.tax / parts;
      final baseTotal = item.total / parts;

      double subtotalAccum = 0;
      double discountAccum = 0;
      double taxAccum = 0;
      double totalAccum = 0;

      for (var idx = 0; idx < parts; idx++) {
        final isLast = idx == parts - 1;
        final lineSubtotal = isLast
            ? item.subtotal - subtotalAccum
            : baseSubtotal;
        final lineDiscount = isLast
            ? item.discounts - discountAccum
            : baseDiscount;
        final lineTax = isLast ? item.tax - taxAccum : baseTax;
        final lineTotal = isLast ? item.total - totalAccum : baseTotal;

        separated.add(
          item.copyWith(
            quantity: 1,
            subtotal: lineSubtotal,
            discounts: lineDiscount,
            tax: lineTax,
            total: lineTotal,
          ),
        );

        subtotalAccum += lineSubtotal;
        discountAccum += lineDiscount;
        taxAccum += lineTax;
        totalAccum += lineTotal;
      }
    }

    return separated;
  }

  static String _formatQty(double qty) {
    if ((qty - qty.roundToDouble()).abs() < 0.001) {
      return qty.toStringAsFixed(0);
    }
    if ((qty * 10 - (qty * 10).roundToDouble()).abs() < 0.001) {
      return qty.toStringAsFixed(1);
    }
    return qty.toStringAsFixed(2);
  }

  static String _getPaymentMethodName(Payment payment) {
    final explicitName = payment.paymentMethodName?.trim();
    if (explicitName != null && explicitName.isNotEmpty) {
      return explicitName.toUpperCase();
    }

    final explicitCode =
        payment.paymentMethodCode?.toLowerCase().trim() ??
        payment.paymentMethodId.toLowerCase().trim();
    if (explicitCode.contains('cash')) return 'EFECTIVO';
    if (explicitCode.contains('card')) return 'TARJETA';
    if (explicitCode.contains('transfer')) return 'TRANSFERENCIA';
    return 'OTRO';
  }

  /// ============================================================
  /// FACTURA FISCAL
  /// ============================================================
  static PrintTicket generateFiscalInvoice({
    required Order order,
    required List<OrderItem> items,
    required FiscalDocument fiscalDoc,
    required Payment payment,
    required PaymentMethod paymentMethod,
    String? tableName,
    String? waiterName,
    required String businessName,
    String? businessAddress,
    String? businessPhone,
    required String businessRnc,
    String receiptItemDisplayMode = 'grouped',
    List<({String label, double amount})> taxBreakdown = const [],
    bool preferStoredOrderTotals = false,
    bool preferStoredItemTotals = false,
  }) {
    final gen = EscPosGenerator(paperWidth: 80);

    gen.ticketHeader(
      businessName: businessName,
      address: businessAddress,
      phone: businessPhone,
      rnc: businessRnc,
    );

    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered('FACTURA');
    gen.setBold(false);
    gen.setTextSize();
    gen.separator();

    gen.fiscalInfo(
      ncf: fiscalDoc.ncfNumber,
      ncfType: _getNcfTypeName(fiscalDoc.ncfType),
      customerName: fiscalDoc.customerName,
      customerRnc: fiscalDoc.customerRnc,
    );

    gen.orderInfo(
      orderNumber: order.id.substring(0, 8).toUpperCase(),
      tableName: tableName ?? 'N/A',
      dateTime: fiscalDoc.issuedAt,
      waiterName: waiterName,
    );

    final printableItems = _buildPrintableItems(
      items,
      receiptItemDisplayMode: receiptItemDisplayMode,
    );
    // Totales desde items ORIGINALES para paridad al centavo con la pantalla.
    final effectiveTotals = _resolvePrintableTotals(
      order: order,
      items: items,
      preferStoredOrderTotals: preferStoredOrderTotals,
    );

    for (final item in printableItems) {
      gen.orderItem(
        name: item.productName,
        quantity: item.quantity,
        price: _resolvePrintableItemTotal(
          order,
          item,
          preferStoredItemTotals: preferStoredItemTotals,
        ),
        modifiers: item.modifiers.map((m) {
          // Costo total que aporta el modifier a la línea, consistente con
          // catalogGrossAmount y los demás tickets: qty_item × qty_mod × precio.
          final itemQty = item.quantity <= 0 ? 1.0 : item.quantity;
          final modTotal = m.price * itemQty * m.qty;
          return modTotal > 0
              ? '${m.name} (+${_formatMoney(modTotal)})'
              : m.name;
        }).toList(),
      );
      // Indicador para llevar (takeout)
      if (item.isTakeout) {
        gen.setBold(true);
        gen.text('  [PARA LLEVAR]');
        gen.setBold(false);
      }
    }

    // SUBTOTAL/TOTAL: usamos el summary directo, igual que la UI.
    // Ver comentario en generatePrecheck.
    final double displaySubtotal = effectiveTotals.subtotal;

    gen.separator();
    // Estructura: Subtotal → impuestos → Descuentos → TOTAL (matchea la UI).
    gen.textRow('Subtotal:', _formatMoney(displaySubtotal));

    // Tax breakdown — labels normales.
    if (taxBreakdown.isNotEmpty) {
      for (final entry in taxBreakdown) {
        if (entry.amount.abs() < 0.005) continue;
        gen.textRow(entry.label, _formatMoney(entry.amount));
      }
    } else {
      if (effectiveTotals.serviceFee > 0) {
        final servicePct = displaySubtotal > 0
            ? ((effectiveTotals.serviceFee / displaySubtotal) * 100)
                  .toStringAsFixed(0)
            : '0';
        gen.textRow(
          'Servicio ($servicePct%):',
          _formatMoney(effectiveTotals.serviceFee),
        );
      }
      if (effectiveTotals.tax > 0.005) {
        final taxPct = displaySubtotal > 0
            ? ((effectiveTotals.tax / displaySubtotal) * 100).toStringAsFixed(0)
            : '18';
        gen.textRow(
          'ITBIS ($taxPct%):',
          _formatMoney(effectiveTotals.tax),
        );
      }
    }

    if (effectiveTotals.discounts > 0) {
      gen.textRow(
        'Descuentos:',
        '-${_formatMoney(effectiveTotals.discounts)}',
      );
    }

    // Fee de delivery propio: cargo exento, parte del total.
    if (effectiveTotals.deliveryFee > 0) {
      gen.textRow('Delivery:', _formatMoney(effectiveTotals.deliveryFee));
    }

    final double displayTotal = effectiveTotals.total;

    gen.doubleSeparator();
    gen.setBold(true);
    gen.setTextSize(width: 2, height: 2);
    gen.textRow('TOTAL:', _formatMoney(displayTotal));
    gen.setTextSize();
    gen.setBold(false);

    gen.paymentInfo(
      method: paymentMethod.name,
      amount: payment.amount,
      change: payment.changeAmount > 0 ? payment.changeAmount : null,
      reference: payment.reference,
    );

    gen.ticketFooter();
    gen.cut();

    return PrintTicket(
      type: 'fiscal_invoice',
      escPosCommands: gen.getCommands(),
    );
  }

  /// ============================================================
  /// CIERRE DE CAJA
  /// ============================================================
  static PrintTicket generateCashCloseTicket({
    required CashRegisterSession session,
    required Map<String, double> summary,
    required String businessName,
    String? cashierName,
  }) {
    final gen = EscPosGenerator(paperWidth: 80);

    gen.initialize();
    gen.lineFeed();
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(businessName);
    gen.setBold(false);
    gen.setTextSize();
    gen.lineFeed();
    gen.doubleSeparator();

    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered('CIERRE DE CAJA');
    gen.setBold(false);
    gen.setTextSize();
    gen.separator();

    gen.text('Sesión: ${session.id.substring(0, 8).toUpperCase()}');
    if (cashierName != null) gen.text('Cajero: $cashierName');
    gen.text('Apertura: ${_formatDateTime(session.openedAt)}');
    if (session.closedAt != null) {
      gen.text('Cierre: ${_formatDateTime(session.closedAt!)}');
    }
    gen.separator();

    gen.lineFeed();
    gen.setBold(true);
    gen.text('RESUMEN DE EFECTIVO:');
    gen.setBold(false);
    gen.lineFeed();

    gen.textRow(
      'Monto inicial:',
      _formatMoney(summary['start_amount']!),
    );
    gen.textRow('Ventas:', _formatMoney(summary['sales']!));
    gen.textRow('Depósitos:', _formatMoney(summary['deposits']!));
    gen.textRow('Gastos:', '-${_formatMoney(summary['expenses']!)}');
    gen.textRow('Retiros:', '-${_formatMoney(summary['withdrawals']!)}');

    gen.doubleSeparator();

    gen.setBold(true);
    gen.setTextSize(width: 2, height: 2);
    gen.textRow('ESPERADO:', _formatMoney(summary['expected_cash']!));
    gen.setTextSize();
    gen.setBold(false);

    if (session.endAmount != null) {
      gen.lineFeed();
      gen.textRow('Contado:', _formatMoney(session.endAmount!));

      final diff = session.endAmount! - summary['expected_cash']!;
      if (diff != 0) {
        gen.setBold(true);
        gen.textRow(
          'Diferencia:',
          '${diff > 0 ? '+' : ''}${_formatMoney(diff.abs())}',
        );
        gen.setBold(false);
      }
    }

    gen.lineFeed(3);
    gen.cut();

    return PrintTicket(type: 'cash_close', escPosCommands: gen.getCommands());
  }

  // ============================================================
  // UTILIDADES
  // ============================================================

  static String _getNcfTypeName(String code) {
    // Nombres oficiales segun DGII (Norma General 01-2020 y siguientes).
    // Se mantienen los aliases sin prefijo letra ('01', '32', etc.) por
    // compat con call sites que pasan solo el codigo numerico.
    switch (code) {
      case 'B01':
      case '01':
        return 'Crédito Fiscal';
      case 'B02':
      case '02':
        return 'Consumidor Final';
      case 'B14':
      case '14':
        return 'Régimen Especial';
      case 'B15':
      case '15':
        return 'Gubernamental';
      case 'E31':
      case '31':
        return 'Factura de Crédito Fiscal Electrónica';
      case 'E32':
      case '32':
        return 'Factura de Consumo Electrónica';
      case 'E33':
      case '33':
        return 'Nota de Débito Electrónica';
      case 'E34':
      case '34':
        return 'Nota de Crédito Electrónica';
      case 'E44':
      case '44':
        return 'Factura de Régimen Especial Electrónica';
      case 'E45':
      case '45':
        return 'Factura Gubernamental Electrónica';
      default:
        return code;
    }
  }

  /// Sprint Caja Pro — Recibo de movimiento manual de caja
  /// (ingreso, retiro o gasto). Se imprime al confirmar el movimiento
  /// para que el cajero entregue copia física a quien recibe/firma.
  static PrintTicket generateCashMovementReceipt({
    required String businessName,
    required String movementType, // 'deposit' | 'withdrawal' | 'expense'
    required double amount,
    required String reasonLabel,
    String? description,
    String? cashierName,
    String? approvedByName,
    String? sessionId,
    DateTime? when,
    /// Moneda base del negocio. Default DOP preserva el formato `RD$` legacy.
    BusinessCurrency? currency,
  }) {
    _currency = currency ?? BusinessCurrency.fallbackDop;
    final gen = EscPosGenerator(paperWidth: 80);
    gen.initialize();

    gen.lineFeed();
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(businessName);
    gen.setBold(false);
    gen.setTextSize();
    gen.lineFeed();
    gen.doubleSeparator();

    final (title, prefix) = switch (movementType) {
      'deposit'    => ('INGRESO A CAJA', '+ '),
      'withdrawal' => ('RETIRO DE CAJA', '- '),
      'expense'    => ('GASTO DE CAJA',  '- '),
      _            => ('MOVIMIENTO',      ''),
    };

    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(title);
    gen.setBold(false);
    gen.setTextSize();
    gen.separator();

    final now = when ?? DateTime.now();
    gen.text('Fecha: ${_formatDate(now)}');
    gen.text('Hora:  ${_formatTime(now)}');
    if (sessionId != null && sessionId.isNotEmpty) {
      gen.text('Sesión: ${sessionId.substring(0, 8).toUpperCase()}');
    }
    if (cashierName != null && cashierName.isNotEmpty) {
      gen.text('Cajero: ${cashierName.toUpperCase()}');
    }
    if (approvedByName != null && approvedByName.isNotEmpty) {
      gen.text('Autorizado por: ${approvedByName.toUpperCase()}');
    }
    gen.separator();

    gen.setBold(true);
    gen.text('RAZÓN:');
    gen.setBold(false);
    gen.text(reasonLabel);
    if (description != null && description.isNotEmpty) {
      gen.lineFeed();
      gen.setBold(true);
      gen.text('Nota:');
      gen.setBold(false);
      gen.text(description);
    }
    gen.doubleSeparator();

    gen.setBold(true);
    gen.setTextSize(width: 2, height: 2);
    gen.textRow('MONTO:', '$prefix ${_formatMoney(amount)}');
    gen.setTextSize();
    gen.setBold(false);
    gen.lineFeed();

    gen.text('______________________________');
    gen.textCentered('Firma');
    gen.lineFeed();

    gen.textCentered(_formatDateTime(now));
    gen.lineFeed();
    gen.cut();

    return PrintTicket(
      type: 'cash_movement',
      escPosCommands: gen.getCommands(),
    );
  }

  /// Formatear fecha (solo día/mes/año)
  static String _formatDate(DateTime dt) {
    final ast = AppTime.astFromInstant(dt);
    return '${ast.day.toString().padLeft(2, '0')}/${ast.month.toString().padLeft(2, '0')}/${ast.year}';
  }

  /// Formatear hora (solo hora:minuto:segundo)
  static String _formatTime(DateTime dt) {
    final ast = AppTime.astFromInstant(dt);
    return '${ast.hour.toString().padLeft(2, '0')}:${ast.minute.toString().padLeft(2, '0')}:${ast.second.toString().padLeft(2, '0')}';
  }

  /// Formatear fecha y hora completa (para otros usos)
  static String _formatDateTime(DateTime dt) {
    final ast = AppTime.astFromInstant(dt);
    return '${_formatDate(ast)} ${ast.hour.toString().padLeft(2, '0')}:${ast.minute.toString().padLeft(2, '0')}';
  }

  /// Regex compartido para extraer el porcentaje de una label tipo
  /// "ITBIS (18%)" / "Propina Ley (10%)" / "ITBIS (16.5%)". Si la label
  /// no encaja, el caller cae al path heurístico legacy.
  static final RegExp _invoiceRateRegex = RegExp(
    r'\((\d+(?:[.,]\d+)?)\s*%\)',
  );

  static double? _parseInvoiceRatePercent(String label) {
    final match = _invoiceRateRegex.firstMatch(label);
    if (match == null) return null;
    final raw = match.group(1)?.replaceAll(',', '.') ?? '';
    return double.tryParse(raw);
  }

  /// Formatear dinero con comas como separador de miles y punto para decimales
  /// Formatea un monto con la moneda activa del negocio: símbolo, decimales
  /// y agrupación de miles según [_currency]. (Antes asumía siempre `RD$` y 2
  /// decimales; el símbolo se prefijaba en cada call site — ahora va aquí.)
  static String _formatMoney(double amount) {
    return _currency.formatAmount(amount);
  }

  /// Separador delgado (líneas simples)
  static void _thinSeparator(EscPosGenerator gen) {
    gen.textCentered('-' * 48);
  }

  /// Separador grueso (líneas dobles)
  static void _thickSeparator(EscPosGenerator gen) {
    gen.textCentered('=' * 48);
  }

  /// PRD 6 — Renderiza el equivalente USD debajo del TOTAL.
  ///
  /// Aparece SOLO si `usdSettings.isUsable` (toggle activo + tasa > 0).
  /// Salida (ejemplo):
  /// ```
  /// ≈ US$ 89.26
  /// Tasa: RD$ 60.5000
  /// ```
  ///
  /// PRD §6.2/§6.3: posición debajo del total, tipografía menor, sin
  /// negrita. El símbolo respeta `usd_symbol_position` (before/after).
  static void _renderUsdEquivalent(
    EscPosGenerator gen,
    double dopTotal,
    UsdDisplaySettings? usdSettings, {
    bool showRate = true,
  }) {
    // Blindaje: cualquier error (formato de número, símbolo raro, etc.)
    // se silencia. PRD 6 es DISPLAY-ONLY — nunca debe romper la
    // impresión del ticket fiscal/precuenta.
    try {
      if (usdSettings == null || !usdSettings.isUsable) return;
      final rate = usdSettings.rate;
      if (rate == null) return;
      if (!dopTotal.isFinite) return;

      final equivalent = calculateUsdEquivalent(
        dopTotal: Decimal.parse(dopTotal.toStringAsFixed(2)),
        usdRate: rate,
      );
      if (equivalent == null) return;

      final sym = usdSettings.symbol;
      final equivFormatted = equivalent.toStringAsFixed(2);
      final equivLabel = usdSettings.symbolPosition == 'after'
          ? '$equivFormatted $sym'
          : '$sym $equivFormatted';

      // Nota: usamos `~` (ASCII 0x7E) en lugar de `≈` (U+2248). El char
      // unicode `≈` no está en Latin-1 y `Latin1Codec.encode` lanza
      // excepción con cualquier codepoint > 0xFF (`allowInvalid: true`
      // solo aplica al decoder), lo que tumbaba todo el bloque USD.
      gen.lineFeed();
      gen.setBold(true);
      gen.textRow('Total USD:', '~ $equivLabel');
      gen.setBold(false);
      if (showRate) {
        gen.textRow('Tasa:', '${_currency.symbol} ${rate.toStringAsFixed(4)}');
      }
    } catch (_) {
      // Silencioso: el ticket sigue saliendo sin el bloque USD.
    }
  }

  /// Itera la lista [blocks] en orden y renderiza solo los enabled cuyo
  /// valor asociado no sea null/vacio. Usado por factura y pre-cuenta
  /// (mismos bloques disponibles, mismo orden).
  ///
  /// Skip silencioso cuando un bloque enabled no tiene contenido (e.g.
  /// `email` enabled pero el negocio no configuro email): NO imprime
  /// nada en su lugar para no dejar lineas en blanco.
  static void _renderHeaderBlocks(
    EscPosGenerator gen, {
    required List<TicketBlock> blocks,
    List<int>? logoBytes,
    String? businessName,
    String? slogan,
    String? legalName,
    String? branchName,
    String? address,
    String? phone,
    String? email,
    String? rnc,
  }) {
    for (final block in blocks) {
      if (!block.enabled) continue;
      switch (block.key) {
        case 'logo':
          if (logoBytes != null && logoBytes.isNotEmpty) {
            gen.appendRaw(logoBytes);
            gen.lineFeed();
          }
          break;
        case 'business_name':
          if (businessName != null && businessName.isNotEmpty) {
            gen.setBold(true);
            gen.textCentered(businessName.toUpperCase());
            gen.setBold(false);
          }
          break;
        case 'slogan':
          if (slogan != null && slogan.isNotEmpty) {
            gen.textCentered(slogan);
          }
          break;
        case 'legal_name':
          if (legalName != null &&
              legalName.isNotEmpty &&
              legalName != businessName) {
            gen.textCentered(legalName);
          }
          break;
        case 'branch_name':
          if (branchName != null && branchName.isNotEmpty) {
            gen.textCentered('Sucursal: $branchName');
          }
          break;
        case 'address':
          if (address != null && address.isNotEmpty) {
            gen.textCentered(address);
          }
          break;
        case 'phone':
          if (phone != null && phone.isNotEmpty) {
            gen.textCentered('Tel: $phone');
          }
          break;
        case 'email':
          if (email != null && email.isNotEmpty) {
            gen.textCentered(email);
          }
          break;
        case 'rnc':
          if (rnc != null && rnc.isNotEmpty) {
            gen.textCentered('RNC: $rnc');
          }
          break;
        // Keys desconocidas: skip. Defensivo para que clientes con
        // listas de bloques de versiones futuras no rompan el ticket.
        default:
          break;
      }
    }
  }

  /// Idem para el footer. Renderiza linefeed entre bloques visibles para
  /// que queden separados visualmente.
  static void _renderFooterBlocks(
    EscPosGenerator gen, {
    required List<TicketBlock> blocks,
    String? footerMessage,
    String thankYouText = 'GRACIAS POR SU PREFERENCIA',
  }) {
    var first = true;
    for (final block in blocks) {
      if (!block.enabled) continue;
      String? text;
      switch (block.key) {
        case 'footer_message':
          text = (footerMessage != null && footerMessage.trim().isNotEmpty)
              ? footerMessage.trim()
              : null;
          break;
        case 'thank_you':
          text = thankYouText;
          break;
        default:
          text = null;
      }
      if (text == null) continue;
      if (!first) gen.lineFeed();
      gen.textCentered(text);
      first = false;
    }
  }
}

class _PrintableReceiptTotals {
  final double subtotal;
  final double discounts;
  final double serviceFee;
  final double tax;
  final double total;

  /// Fee de delivery propio: cargo EXENTO ya incluido en [total].
  final double deliveryFee;

  const _PrintableReceiptTotals({
    required this.subtotal,
    required this.discounts,
    required this.serviceFee,
    required this.tax,
    required this.total,
    this.deliveryFee = 0,
  });
}

/// Resultado de [PrintTicketService._resolveRecomputeContext]: criterio
/// compartido por la línea por ítem y el bloque de totales para recomputar
/// el SUBTOTAL/impuestos del ticket de forma consistente.
class _RecomputeContext {
  /// Descuento como nota informativa (no sustractiva) bajo los impuestos.
  final bool isPostDiscountMode;

  /// Tasa por línea del breakdown (paralelo a `taxBreakdown`); `null` si la
  /// label no era parseable.
  final List<double?> lineRates;

  /// Suma de tasas declaradas (ej. 0.28 = 10% Ley + 18% ITBIS).
  final double declaredRate;

  /// `true` solo si todas las tasas son conocidas, uniformes y > 0; habilita
  /// la recomputación inversa desde el TOTAL.
  final bool canRecompute;

  const _RecomputeContext({
    required this.isPostDiscountMode,
    required this.lineRates,
    required this.declaredRate,
    required this.canRecompute,
  });
}
