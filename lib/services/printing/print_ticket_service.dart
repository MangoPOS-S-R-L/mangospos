import '../../data/models/printing_models.dart';
import '../../data/models/sales_models.dart';
import '../../data/models/payment_models.dart';
import '../../core/utils/app_time.dart';
import '../../data/utils/order_pricing_utils.dart';
import 'esc_pos_generator.dart';

/// 🖨️ Servicio de generación de tickets
class PrintTicketService {
  /// ============================================================
  /// COMANDA DE COCINA
  /// ============================================================
  static PrintTicket generateKitchenTicket({
    required Order order,
    required List<OrderItem> items,
    required String tableName,
    String? waiterName,
    String? businessName,
    bool isReprint = false,
    String receiptItemDisplayMode = 'grouped',
  }) {
    final gen = EscPosGenerator(paperWidth: 80);
    final printableItems = _buildPrintableItems(
      items,
      receiptItemDisplayMode: receiptItemDisplayMode,
    );

    gen.initialize();
    gen.lineFeed();

    final resolvedBusinessName = businessName?.trim();
    if (resolvedBusinessName != null && resolvedBusinessName.isNotEmpty) {
      gen.setTextSize(width: 1, height: 2);
      gen.setBold(true);
      gen.textCenteredWrapped(resolvedBusinessName.toUpperCase());
      gen.setBold(false);
      gen.setTextSize();
      gen.lineFeed();
    }

    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(isReprint ? 'REIMPRESIÓN COMANDA' : 'COMANDA DE COCINA');
    gen.setBold(false);
    gen.setTextSize();
    gen.doubleSeparator();

    gen.setBold(true);
    gen.text('ORDEN: ${order.id.substring(0, 8).toUpperCase()}');
    gen.setBold(false);

    if (tableName.isNotEmpty) {
      gen.text('MESA: $tableName');
    }

    if (waiterName != null && waiterName.isNotEmpty) {
      gen.text('MESERO: $waiterName');
    }

    final dateStr = _formatDate(order.createdAt);
    final timeStr = _formatTime(order.createdAt);
    gen.text('FECHA: $dateStr');
    gen.text('HORA: $timeStr');

    gen.lineFeed();
    gen.separator();

    for (var idx = 0; idx < printableItems.length; idx++) {
      final item = printableItems[idx];
      gen.setTextSize(width: 2, height: 2);
      gen.setBold(true);
      final itemPrefix = 'x${_formatQty(item.quantity)} ';
      final itemNameLines = _wrapKitchenItemName(
        item.productName,
        prefix: itemPrefix,
        maxChars: 20,
      );
      for (var lineIndex = 0; lineIndex < itemNameLines.length; lineIndex++) {
        final line = lineIndex == 0
            ? '$itemPrefix${itemNameLines[lineIndex]}'
            : '   ${itemNameLines[lineIndex]}';
        gen.text(line);
      }
      gen.setBold(false);
      gen.setTextSize();

      if (item.isTakeout) {
        gen.text('  [PARA LLEVAR]');
      }

      if (item.modifiers.isNotEmpty) {
        for (final mod in item.modifiers) {
          gen.text('  + ${mod.name}');
        }
      }

      if (item.notes != null && item.notes!.isNotEmpty) {
        gen.setBold(true);
        gen.text('NOTA: ${item.notes}');
        gen.setBold(false);
      }

      gen.separator();
    }

    gen.lineFeed(2);
    gen.lineFeed(3);
    gen.cut();

    return PrintTicket(
      type: 'kitchen_order',
      escPosCommands: gen.getCommands(),
    );
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
  }) {
    final gen = EscPosGenerator(paperWidth: 80);
    final consolidatedItems = _buildPrintableItems(
      items,
      receiptItemDisplayMode: receiptItemDisplayMode,
    );

    gen.initialize();
    gen.lineFeed(2);

    // ════════════════════════════════════════════
    // HEADER - Nombre del negocio
    // ════════════════════════════════════════════
    if (businessName != null && businessName.isNotEmpty) {
      gen.setBold(true);
      gen.textCentered(businessName.toUpperCase());
      gen.setBold(false);
    }
    if (legalName != null &&
        legalName.isNotEmpty &&
        legalName != businessName) {
      gen.textCentered(legalName);
    }

    // Info de contacto centrada
    if (businessRnc != null && businessRnc.isNotEmpty) {
      gen.textCentered('RNC: $businessRnc');
    }
    if (businessAddress != null && businessAddress.isNotEmpty) {
      gen.textCentered(businessAddress);
    }
    if (businessPhone != null && businessPhone.isNotEmpty) {
      gen.textCentered('Tel: $businessPhone');
    }

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
          ? itemDisplayTotal(order, item)
          : itemDisplayUnitPrice(order, item);

      // Nombre del producto en negrita
      gen.setBold(true);
      gen.text(item.productName);
      gen.setBold(false);

      // Cantidad x precio unitario ......... TOTAL
      final displayQty = _formatQty(item.quantity);

      final leftPart = '$displayQty x RD\$ ${_formatMoney(unitPrice)}';
      final rightPart = 'RD\$ ${_formatMoney(itemDisplayTotal(order, item))}';
      gen.dotRow(leftPart, rightPart);

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

    final printableSummary = summarizeOrderPricing(order, consolidatedItems);
    final printableSubtotal = printableSummary.subtotal;
    final printableDiscounts = printableSummary.discounts;
    final printableTax = printableSummary.tax;
    final printableServiceFee = printableSummary.serviceFee;
    final printableGrandTotal = printableSummary.total;

    // Subtotal
    gen.textRow('SUBTOTAL:', 'RD\$ ${_formatMoney(printableSubtotal)}');

    // Descuentos
    if (printableDiscounts > 0) {
      gen.textRow('DESCUENTO:', '-RD\$ ${_formatMoney(printableDiscounts)}');
    }

    // Cargo por servicio
    if (printableServiceFee > 0) {
      final servicePct = printableSubtotal > 0
          ? ((printableServiceFee / printableSubtotal) * 100).toStringAsFixed(0)
          : '0';
      gen.textRow(
        'SERVICIO ($servicePct%):',
        'RD\$ ${_formatMoney(printableServiceFee)}',
      );
    }

    // ITBIS
    gen.textRow('ITBIS (18%):', 'RD\$ ${_formatMoney(printableTax)}');

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
    // FOOTER
    // ════════════════════════════════════════════
    gen.lineFeed();
    gen.textCentered('GRACIAS POR SU PREFERENCIA');
    gen.lineFeed();
    gen.textCentered('Por favor verifique los datos');
    gen.textCentered('antes de proceder al pago');
    gen.lineFeed();

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
  }) {
    final gen = EscPosGenerator(paperWidth: 80);

    gen.initialize();
    gen.lineFeed(2);

    // Header
    if (businessName != null && businessName.isNotEmpty) {
      gen.setBold(true);
      gen.textCentered(businessName.toUpperCase());
      gen.setBold(false);
    }
    if (legalName != null &&
        legalName.isNotEmpty &&
        legalName != businessName) {
      gen.textCentered(legalName);
    }
    if (businessAddress != null && businessAddress.isNotEmpty) {
      gen.textCentered(businessAddress);
    }
    if (businessPhone != null && businessPhone.isNotEmpty) {
      gen.textCentered('Tel: $businessPhone');
    }
    if (businessRnc != null && businessRnc.isNotEmpty) {
      gen.textCentered('RNC: $businessRnc');
    }

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

    // Order Info
    gen.setBold(true);
    gen.textRow('ORDEN:', order.id.substring(0, 8).toUpperCase());
    gen.setBold(false);
    if (fiscalNcf != null && fiscalNcf.isNotEmpty) {
      if (fiscalType != null) {
        gen.textRow('TIPO:', _getNcfTypeName(fiscalType));
      }
      gen.textRow('NCF:', fiscalNcf);
    } else if (fiscalType != null) {
      gen.textRow('TIPO:', _getNcfTypeName(fiscalType));
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
      final unitPrice = itemDisplayUnitPrice(order, item);

      gen.setBold(true);
      gen.text(item.productName);
      gen.setBold(false);

      final displayQty = _formatQty(item.quantity);

      final leftPart = '$displayQty x RD\$ ${_formatMoney(unitPrice)}';
      final rightPart = 'RD\$ ${_formatMoney(itemDisplayTotal(order, item))}';
      gen.dotRow(leftPart, rightPart);

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
    final printableSummary = summarizeOrderPricing(order, consolidatedItems);

    gen.textRow('SUBTOTAL:', 'RD\$ ${_formatMoney(printableSummary.subtotal)}');
    if (printableSummary.discounts > 0) {
      gen.textRow(
        'DESCUENTO:',
        '-RD\$ ${_formatMoney(printableSummary.discounts)}',
      );
    }
    if (printableSummary.serviceFee > 0) {
      final servicePct = printableSummary.subtotal > 0
          ? ((printableSummary.serviceFee / printableSummary.subtotal) * 100)
                .toStringAsFixed(0)
          : '0';
      gen.textRow(
        'SERVICIO ($servicePct%):',
        'RD\$ ${_formatMoney(printableSummary.serviceFee)}',
      );
    }
    gen.textRow('ITBIS (18%):', 'RD\$ ${_formatMoney(printableSummary.tax)}');

    gen.lineFeed();
    _thickSeparator(gen);
    gen.lineFeed();

    gen.setBold(true);
    gen.setTextSize(width: 2, height: 2);
    gen.textRow('TOTAL:', 'RD\$ ${_formatMoney(printableSummary.total)}');
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

    // Footer
    gen.lineFeed(2);
    gen.textCentered('GRACIAS POR SU PREFERENCIA');
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
      );
    }

    return consolidatedByKey.values.toList(growable: false);
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

    for (final item in items) {
      gen.orderItem(
        name: item.productName,
        quantity: item.quantity,
        price: item.total,
        modifiers: item.modifiers.map((m) => m.name).toList(),
      );
    }

    gen.totals(
      subtotal: order.subtotal,
      discounts: order.discounts > 0 ? order.discounts : null,
      serviceFee: order.serviceFee > 0 ? order.serviceFee : null,
      tax: order.tax,
      total: order.total,
    );

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
        return 'e-Crédito Fiscal';
      case 'E32':
      case '32':
        return 'e-Consumidor';
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
}
