import '../../data/models/business_profile.dart';
import '../../data/models/printing_models.dart';
import '../../data/models/sales_models.dart';
import '../../data/models/payment_models.dart';
import '../../core/utils/app_time.dart';
import '../../data/utils/order_pricing_utils.dart';
import 'esc_pos_generator.dart';

/// 🖨️ Servicio de generación de tickets
class PrintTicketService {
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
    final useStoredTotals = hasStoredTotals && summaryIsDegenerate;

    if (!useStoredTotals) {
      return _PrintableReceiptTotals(
        subtotal: summary.subtotal,
        discounts: summary.discounts,
        serviceFee: summary.serviceFee,
        tax: summary.tax,
        total: summary.total,
      );
    }

    return _PrintableReceiptTotals(
      subtotal: order.subtotal,
      discounts: order.discounts,
      serviceFee: order.serviceFee,
      tax: order.tax,
      total: order.total,
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
    String? businessName, // ya no se usa en el nuevo diseño, se ignora.
    String? areaCode,
    bool isReprint = false,
    String receiptItemDisplayMode = 'grouped',
  }) {
    final gen = EscPosGenerator(paperWidth: 80);
    final printableItems = _buildPrintableItems(
      items,
      receiptItemDisplayMode: receiptItemDisplayMode,
    );

    // Particionar por isTakeout. Mantener orden relativo dentro de cada
    // grupo igual al orden original.
    final regularItems = printableItems.where((i) => !i.isTakeout).toList();
    final takeoutItems = printableItems.where((i) => i.isTakeout).toList();

    gen.initialize();
    gen.lineFeed();

    // ─── HEADER: CAJERO ─────────────────────────────────────────────
    final resolvedCashier = cashierName?.trim();
    if (resolvedCashier != null && resolvedCashier.isNotEmpty) {
      _kitchenDashedSeparator(gen);
      gen.textCentered('CAJERO: ${resolvedCashier.toUpperCase()}');
      _kitchenDashedSeparator(gen);
      gen.lineFeed();
    }

    // ─── TITULO en 2 lineas ─────────────────────────────────────────
    final (titleMain, titleSub) = _kitchenTitleParts(areaCode);
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(isReprint ? 'REIMPRESIÓN' : titleMain);
    gen.setBold(false);
    gen.setTextSize();
    gen.textCentered(titleSub);
    gen.doubleSeparator();

    // ─── INFO DE ORDEN en 2 columnas ────────────────────────────────
    gen.textRow('ORDEN', 'MESA');
    gen.setBold(true);
    gen.textRow(
      '#${order.id.substring(0, 8).toUpperCase()}',
      tableName.isNotEmpty ? tableName : '-',
    );
    gen.setBold(false);
    gen.lineFeed();

    if ((waiterName != null && waiterName.isNotEmpty) ||
        order.createdAt.year > 1970) {
      gen.textRow('MESERO', 'HORA');
      gen.setBold(true);
      gen.textRow(
        (waiterName?.isNotEmpty ?? false) ? waiterName! : '-',
        _formatTime(order.createdAt),
      );
      gen.setBold(false);
      gen.lineFeed();
    }

    gen.text(_formatDate(order.createdAt));
    gen.doubleSeparator();

    // ─── ITEMS REGULARES ────────────────────────────────────────────
    for (var i = 0; i < regularItems.length; i++) {
      _renderKitchenItem(gen, regularItems[i]);
      if (i < regularItems.length - 1) {
        _kitchenDashedSeparator(gen);
      }
    }

    // ─── PARA LLEVAR (recuadro inverse) ─────────────────────────────
    if (takeoutItems.isNotEmpty) {
      if (regularItems.isNotEmpty) gen.lineFeed();
      _kitchenInverseLabel(gen, 'PARA LLEVAR');
      gen.lineFeed();
      for (var i = 0; i < takeoutItems.length; i++) {
        _renderKitchenItem(gen, takeoutItems[i]);
        if (i < takeoutItems.length - 1) {
          _kitchenDashedSeparator(gen);
        }
      }
    }

    // ─── FOOTER ─────────────────────────────────────────────────────
    gen.lineFeed();
    _kitchenDashedSeparator(gen);
    final now = DateTime.now();
    final hms =
        '${_formatTime(now)}:${now.second.toString().padLeft(2, '0')}';
    gen.textCentered(
      resolvedCashier != null && resolvedCashier.isNotEmpty
          ? '$hms · $resolvedCashier'
          : hms,
    );

    gen.lineFeed(3);
    gen.cut();

    return PrintTicket(
      type: 'kitchen_order',
      escPosCommands: gen.getCommands(),
    );
  }

  /// Separador entre items. Linea solida `-----` en lugar de dashed
  /// disperso `- - - -`: se imprime mas definida en termicas economicas
  /// donde la dashed sale debil/punteada. Linefeed al rededor para mas
  /// "respiracion" y mejor legibilidad en cocina.
  static void _kitchenDashedSeparator(EscPosGenerator gen) {
    gen.lineFeed();
    gen.text('-' * 48);
    gen.lineFeed();
  }

  /// Linea con label centrado en video inverso (rectangulo negro con
  /// texto blanco). Algunos firmwares ESC/POS no soportan GS B 1 — en
  /// ese caso se imprime el texto normal centrado, igual visible.
  static void _kitchenInverseLabel(EscPosGenerator gen, String label) {
    const totalWidth = 48;
    final upper = label.toUpperCase();
    final padTotal = totalWidth - upper.length;
    final left = padTotal ~/ 2;
    final right = padTotal - left;
    final padded = ' ' * left + upper + ' ' * right;
    gen.setInverse(true);
    gen.setBold(true);
    gen.text(padded);
    gen.setBold(false);
    gen.setInverse(false);
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

  static void _renderKitchenItem(EscPosGenerator gen, OrderItem item) {
    // Linea principal: cantidad + nombre en font 2x ancho/alto, bold.
    // Sin recuadro inverso — se imprime peor en termicas economicas.
    // El bold + tamaño grande dan mejor legibilidad y "calidad" visual.
    final qty = _formatQty(item.quantity);
    final prefix = '$qty  '; // 2 espacios entre cantidad y nombre.
    // Wrap considerando que en font 2x2 cabe ~24 chars en 80mm.
    final nameLines = _wrapKitchenItemName(
      item.productName,
      prefix: prefix,
      maxChars: 22,
    );

    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    for (var i = 0; i < nameLines.length; i++) {
      if (i == 0) {
        gen.text('$prefix${nameLines[i]}');
      } else {
        // Indent con el ancho del prefix (qty + 2 spaces) para que el
        // wrap se alinee bajo el inicio del nombre.
        gen.text('${' ' * prefix.length}${nameLines[i]}');
      }
    }
    gen.setBold(false);
    gen.setTextSize();

    if (item.modifiers.isNotEmpty) {
      for (final mod in item.modifiers) {
        final isComboChoice = mod.name.contains(': ');
        final priceSuffix = mod.price > 0
            ? ' (+RD\$ ${_formatMoney(mod.price)})'
            : '';
        gen.text(
          isComboChoice
              ? '  • ${mod.name}$priceSuffix'
              : '  + ${mod.name}$priceSuffix',
        );
      }
    }

    if (item.notes != null && item.notes!.isNotEmpty) {
      gen.setBold(true);
      gen.text('NOTA: ${item.notes}');
      gen.setBold(false);
    }
  }

  /// ============================================================
  /// PRECUENTA - DISEÑO TÉRMICO MEJORADO
  /// ============================================================
  static PrintTicket generatePrecheck({
    required Order order,
    required List<OrderItem> items,
    required String tableName,
    String? waiterName,
    String? businessName,
    String? legalName,
    String? businessAddress,
    String? businessPhone,
    String? businessRnc,
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
  }) {
    final gen = EscPosGenerator(paperWidth: 80);
    final consolidatedItems = _buildPrintableItems(
      items,
      receiptItemDisplayMode: receiptItemDisplayMode,
    );

    gen.initialize();
    gen.lineFeed(2);

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

    gen.lineFeed();
    _thinSeparator(gen);
    gen.lineFeed();

    // ════════════════════════════════════════════
    // TÍTULO DEL DOCUMENTO
    // ════════════════════════════════════════════
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(title);
    gen.setBold(false);
    gen.setTextSize();

    gen.lineFeed();
    _thickSeparator(gen);
    gen.lineFeed();

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

    gen.lineFeed();
    _thinSeparator(gen);

    // ════════════════════════════════════════════
    // ITEMS - PRODUCTOS (SIN QTY)
    // ════════════════════════════════════════════
    gen.setBold(true);
    gen.textRow('DESCRIPCIÓN', 'TOTAL');
    gen.setBold(false);
    _thinSeparator(gen);
    gen.lineFeed(); // línea en blanco debajo del encabezado

    for (int i = 0; i < consolidatedItems.length; i++) {
      final item = consolidatedItems[i];
      final unitPrice = item.quantity == 0
          ? itemDisplayBaseTotal(order, item)
          : itemDisplayBaseUnitPrice(order, item);

      // Nombre del producto en negrita
      gen.setBold(true);
      gen.text(item.productName);
      gen.setBold(false);

      // Cantidad x precio unitario ......... TOTAL
      final displayQty = _formatQty(item.quantity);

      final leftPart = '$displayQty x RD\$ ${_formatMoney(unitPrice)}';
      final rightPart = 'RD\$ ${_formatMoney(itemDisplayBaseTotal(order, item))}';
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
          gen.text('  + ${mod.name}');
        }
      }

      // Notas especiales destacadas
      if (item.notes != null && item.notes!.isNotEmpty) {
        gen.setBold(true);
        gen.text('  NOTA: ${item.notes}');
        gen.setBold(false);
      }

      // Espacio ligero entre items
      if (i < consolidatedItems.length - 1) {
        gen.lineFeed();
      }
    }

    _thinSeparator(gen);

    // ════════════════════════════════════════════
    // TOTALES
    // ════════════════════════════════════════════
    gen.lineFeed();

    // Totales salen de los items ORIGINALES (no consolidados) para que el
    // subtotal absorba el centavo de redondeo por-item y coincida exactamente
    // con lo que ve el cajero en pantalla. Los items consolidados se usan solo
    // para el render de las lineas del ticket.
    final printableSummary = summarizeOrderPricing(order, items);
    final printableDiscounts = printableSummary.discounts;

    // SUBTOTAL/TOTAL: usamos los valores del summary directo, igual que la UI.
    // El trigger backend guarda `oi.subtotal` pre-descuento; sumar discounts
    // de vuelta sobre-infla. `summary.total` ya aplica el override correcto
    // (inclusiveGrossNet para órdenes 100% inclusive) y la fórmula
    // base+tax-disc para mixed/exclusive.
    final double printableSubtotal = printableSummary.subtotal;

    // Estructura del bloque de totales (matchea la UI):
    //   SUBTOTAL → impuestos → DESCUENTO → TOTAL
    gen.textRow('SUBTOTAL:', 'RD\$ ${_formatMoney(printableSubtotal)}');

    // Tax breakdown — labels normales.
    if (taxBreakdown.isNotEmpty) {
      for (final entry in taxBreakdown) {
        if (entry.amount.abs() < 0.005) continue;
        gen.textRow('${entry.label}:', 'RD\$ ${_formatMoney(entry.amount)}');
      }
    } else {
      // Fallback: derivar desde printableSummary.
      final printableTax = printableSummary.tax;
      final printableServiceFee = printableSummary.serviceFee;
      if (printableServiceFee > 0) {
        final servicePct = printableSubtotal > 0
            ? ((printableServiceFee / printableSubtotal) * 100).toStringAsFixed(
                0,
              )
            : '0';
        gen.textRow(
          'SERVICIO ($servicePct%):',
          'RD\$ ${_formatMoney(printableServiceFee)}',
        );
      }
      if (printableTax > 0.005) {
        gen.textRow('ITBIS:', 'RD\$ ${_formatMoney(printableTax)}');
      }
    }

    // Descuento (después de los impuestos, como en la UI).
    if (printableDiscounts > 0) {
      gen.textRow('DESCUENTO:', '-RD\$ ${_formatMoney(printableDiscounts)}');
    }

    final double printableGrandTotal = printableSummary.total;

    gen.lineFeed();
    _thickSeparator(gen);
    gen.lineFeed();

    // ════════════════════════════════════════════
    // TOTAL FINAL - Tamaño grande
    // ════════════════════════════════════════════
    gen.setBold(true);
    gen.setTextSize(width: 2, height: 2);
    gen.textRow('TOTAL:', 'RD\$ ${_formatMoney(printableGrandTotal)}');
    gen.setTextSize();
    gen.setBold(false);

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

    gen.lineFeed(4);
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
    DateTime? issuedAt,
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
  }) {
    final gen = EscPosGenerator(paperWidth: 80);

    gen.initialize();
    gen.lineFeed(2);

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

    gen.lineFeed();
    _thinSeparator(gen);
    gen.lineFeed();

    // Title
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(title);
    gen.setBold(false);
    gen.setTextSize();

    gen.lineFeed();
    _thickSeparator(gen);
    gen.lineFeed();

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

    gen.lineFeed();
    _thinSeparator(gen);

    // Items
    gen.setBold(true);
    gen.textRow('DESCRIPCIÓN', 'TOTAL');
    gen.setBold(false);
    _thinSeparator(gen);
    gen.lineFeed();

    final consolidatedItems = _buildPrintableItems(
      items,
      receiptItemDisplayMode: receiptItemDisplayMode,
    );

    for (int i = 0; i < consolidatedItems.length; i++) {
      final item = consolidatedItems[i];
      final unitPrice = _resolvePrintableItemUnitPrice(
        order,
        item,
        preferStoredItemTotals: preferStoredItemTotals,
      );

      gen.setBold(true);
      gen.text(item.productName);
      gen.setBold(false);

      final displayQty = _formatQty(item.quantity);
      final lineTotal = _resolvePrintableItemTotal(
        order,
        item,
        preferStoredItemTotals: preferStoredItemTotals,
      );

      final leftPart = '$displayQty x RD\$ ${_formatMoney(unitPrice)}';
      final rightPart = 'RD\$ ${_formatMoney(lineTotal)}';
      gen.dotRow(leftPart, rightPart);

      // Indicador para llevar (takeout)
      if (item.isTakeout) {
        gen.setBold(true);
        gen.text('  [PARA LLEVAR]');
        gen.setBold(false);
      }

      if (item.modifiers.isNotEmpty) {
        for (final mod in item.modifiers) {
          gen.text('  + ${mod.name}');
        }
      }

      if (item.notes != null && item.notes!.isNotEmpty) {
        gen.setBold(true);
        gen.text('  NOTA: ${item.notes}');
        gen.setBold(false);
      }

      if (i < consolidatedItems.length - 1) {
        gen.lineFeed();
      }
    }

    _thinSeparator(gen);
    gen.lineFeed();

    // Totals
    // Ver comentario en generatePrecheck: usamos los items ORIGINALES para
    // que la absorcion del centavo quede en el subtotal y el papel coincida
    // con la pantalla al centavo.
    final effectiveTotals = _resolvePrintableTotals(
      order: order,
      items: items,
      preferStoredOrderTotals: preferStoredOrderTotals,
    );
    final effectiveDiscounts = effectiveTotals.discounts;

    // SUBTOTAL/TOTAL: usamos el summary directo, igual que la UI.
    // Ver comentario en generatePrecheck.
    final double effectiveSubtotal = effectiveTotals.subtotal;

    // Etiquetas DGII para e-CF (Norma General 01-2020):
    // - "Subtotal Gravado" en lugar de "SUBTOTAL"
    // - "Total ITBIS" en lugar de "ITBIS (18%)"
    final subtotalLabel = isElectronicCf ? 'Subtotal Gravado:' : 'SUBTOTAL:';
    gen.textRow(subtotalLabel, 'RD\$ ${_formatMoney(effectiveSubtotal)}');

    // Tax breakdown — para e-CF normaliza el label del ITBIS a "Total ITBIS".
    if (taxBreakdown.isNotEmpty) {
      for (final entry in taxBreakdown) {
        if (entry.amount.abs() < 0.005) continue;
        var label = entry.label;
        if (isElectronicCf && label.toLowerCase().contains('itbis')) {
          label = 'Total ITBIS';
        }
        gen.textRow('$label:', 'RD\$ ${_formatMoney(entry.amount)}');
      }
    } else {
      // Fallback: derive from resolved printable totals
      final effectiveTax = effectiveTotals.tax;
      final effectiveServiceFee = effectiveTotals.serviceFee;
      if (effectiveServiceFee > 0) {
        final servicePct = effectiveSubtotal > 0
            ? ((effectiveServiceFee / effectiveSubtotal) * 100).toStringAsFixed(
                0,
              )
            : '0';
        gen.textRow(
          'SERVICIO ($servicePct%):',
          'RD\$ ${_formatMoney(effectiveServiceFee)}',
        );
      }
      if (effectiveTax > 0.005) {
        if (isElectronicCf) {
          gen.textRow('Total ITBIS:', 'RD\$ ${_formatMoney(effectiveTax)}');
        } else {
          final taxPct = effectiveSubtotal > 0
              ? ((effectiveTax / effectiveSubtotal) * 100).toStringAsFixed(0)
              : '18';
          gen.textRow(
            'ITBIS ($taxPct%):',
            'RD\$ ${_formatMoney(effectiveTax)}',
          );
        }
      }
    }

    if (effectiveDiscounts > 0) {
      gen.textRow('DESCUENTO:', '-RD\$ ${_formatMoney(effectiveDiscounts)}');
    }

    final double effectiveTotal = effectiveTotals.total;

    gen.lineFeed();
    _thickSeparator(gen);
    gen.lineFeed();

    gen.setBold(true);
    gen.setTextSize(width: 2, height: 2);
    gen.textRow('TOTAL:', 'RD\$ ${_formatMoney(effectiveTotal)}');
    gen.setTextSize();
    gen.setBold(false);

    gen.lineFeed();
    _thickSeparator(gen);
    gen.lineFeed();

    // Payments
    if (payments.isNotEmpty) {
      gen.setBold(true);
      gen.text('PAGOS REALIZADOS:');
      gen.setBold(false);

      double totalChange = 0;

      for (final p in payments) {
        final method = _getPaymentMethodName(p);
        gen.textRow(method, 'RD\$ ${_formatMoney(p.amount)}');
        totalChange += p.changeAmount;
      }

      if (totalChange > 0) {
        gen.lineFeed();
        gen.setBold(true);
        gen.textRow('CAMBIO:', 'RD\$ ${_formatMoney(totalChange)}');
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
    gen.lineFeed(2);
    _renderFooterBlocks(
      gen,
      blocks: footerBlocks ?? TicketBlocks.defaultFooter,
      footerMessage: footerMessage,
    );
    gen.lineFeed(4);
    gen.cut();

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
      );
    }

    return consolidatedByKey.values.toList(growable: false);
  }

  /// Suma las cantidades de modificadores coincidentes cuando dos ítems con
  /// el mismo set de modificadores se fusionan en la consolidación.
  /// Sin esto, `catalogGrossAmount` aplica el precio del modificador una sola
  /// vez a una línea con `quantity>1`, produciendo un total menor al real.
  static List<OrderItemModifier> _sumMatchingModifiers(
    List<OrderItemModifier> a,
    List<OrderItemModifier> b,
  ) {
    if (a.length != b.length) {
      return [...a, ...b];
    }
    final merged = <OrderItemModifier>[];
    for (var i = 0; i < a.length; i++) {
      final ma = a[i];
      final mb = b[i];
      merged.add(
        OrderItemModifier(
          id: ma.id,
          itemId: ma.itemId,
          name: ma.name,
          qty: ma.qty + mb.qty,
          price: ma.price,
        ),
      );
    }
    return merged;
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

  static List<String> _wrapKitchenItemName(
    String name, {
    required String prefix,
    required int maxChars,
  }) {
    final normalized = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return [''];

    final firstLineWidth = (maxChars - prefix.length).clamp(8, maxChars);
    final continuationWidth = (maxChars - 3).clamp(8, maxChars);
    final words = normalized.split(' ');
    final lines = <String>[];
    var current = '';
    var currentWidth = firstLineWidth;

    void pushCurrent() {
      if (current.isNotEmpty) {
        lines.add(current);
        current = '';
        currentWidth = continuationWidth;
      }
    }

    for (final word in words) {
      if (word.length > currentWidth) {
        if (current.isNotEmpty) {
          pushCurrent();
        }
        var start = 0;
        while (start < word.length) {
          final width = lines.isEmpty ? firstLineWidth : continuationWidth;
          final end = (start + width < word.length)
              ? start + width
              : word.length;
          lines.add(word.substring(start, end));
          start = end;
          currentWidth = continuationWidth;
        }
        continue;
      }

      final candidate = current.isEmpty ? word : '$current $word';
      if (candidate.length <= currentWidth) {
        current = candidate;
      } else {
        pushCurrent();
        current = word;
      }
    }

    pushCurrent();
    return lines.isEmpty ? [''] : lines;
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
        modifiers: item.modifiers
            .map(
              (m) => m.price > 0
                  ? '${m.name} (+RD\$ ${_formatMoney(m.price)})'
                  : m.name,
            )
            .toList(),
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
    gen.textRow('Subtotal:', 'RD\$ ${_formatMoney(displaySubtotal)}');

    // Tax breakdown — labels normales.
    if (taxBreakdown.isNotEmpty) {
      for (final entry in taxBreakdown) {
        if (entry.amount.abs() < 0.005) continue;
        gen.textRow(entry.label, 'RD\$ ${_formatMoney(entry.amount)}');
      }
    } else {
      if (effectiveTotals.serviceFee > 0) {
        final servicePct = displaySubtotal > 0
            ? ((effectiveTotals.serviceFee / displaySubtotal) * 100)
                  .toStringAsFixed(0)
            : '0';
        gen.textRow(
          'Servicio ($servicePct%):',
          'RD\$ ${_formatMoney(effectiveTotals.serviceFee)}',
        );
      }
      if (effectiveTotals.tax > 0.005) {
        final taxPct = displaySubtotal > 0
            ? ((effectiveTotals.tax / displaySubtotal) * 100).toStringAsFixed(0)
            : '18';
        gen.textRow(
          'ITBIS ($taxPct%):',
          'RD\$ ${_formatMoney(effectiveTotals.tax)}',
        );
      }
    }

    if (effectiveTotals.discounts > 0) {
      gen.textRow(
        'Descuentos:',
        '-RD\$ ${_formatMoney(effectiveTotals.discounts)}',
      );
    }

    final double displayTotal = effectiveTotals.total;

    gen.doubleSeparator();
    gen.setBold(true);
    gen.setTextSize(width: 2, height: 2);
    gen.textRow('TOTAL:', 'RD\$ ${_formatMoney(displayTotal)}');
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
      'RD\$ ${_formatMoney(summary['start_amount']!)}',
    );
    gen.textRow('Ventas:', 'RD\$ ${_formatMoney(summary['sales']!)}');
    gen.textRow('Depósitos:', 'RD\$ ${_formatMoney(summary['deposits']!)}');
    gen.textRow('Gastos:', '-RD\$ ${_formatMoney(summary['expenses']!)}');
    gen.textRow('Retiros:', '-RD\$ ${_formatMoney(summary['withdrawals']!)}');

    gen.doubleSeparator();

    gen.setBold(true);
    gen.setTextSize(width: 2, height: 2);
    gen.textRow('ESPERADO:', 'RD\$ ${_formatMoney(summary['expected_cash']!)}');
    gen.setTextSize();
    gen.setBold(false);

    if (session.endAmount != null) {
      gen.lineFeed();
      gen.textRow('Contado:', 'RD\$ ${_formatMoney(session.endAmount!)}');

      final diff = session.endAmount! - summary['expected_cash']!;
      if (diff != 0) {
        gen.setBold(true);
        gen.textRow(
          'Diferencia:',
          '${diff > 0 ? '+' : ''}RD\$ ${_formatMoney(diff.abs())}',
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

  /// Formatear dinero con comas como separador de miles y punto para decimales
  static String _formatMoney(double amount) {
    final parts = amount.toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final decPart = parts[1];

    // Agregar comas cada 3 dígitos
    String formatted = '';
    int count = 0;
    for (int i = intPart.length - 1; i >= 0; i--) {
      if (count == 3) {
        formatted = ',$formatted';
        count = 0;
      }
      formatted = intPart[i] + formatted;
      count++;
    }

    return '$formatted.$decPart';
  }

  /// Separador delgado (líneas simples)
  static void _thinSeparator(EscPosGenerator gen) {
    gen.textCentered('-' * 48);
  }

  /// Separador grueso (líneas dobles)
  static void _thickSeparator(EscPosGenerator gen) {
    gen.textCentered('=' * 48);
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

  const _PrintableReceiptTotals({
    required this.subtotal,
    required this.discounts,
    required this.serviceFee,
    required this.tax,
    required this.total,
  });
}
