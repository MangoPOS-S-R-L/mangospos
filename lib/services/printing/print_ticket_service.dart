import '../../data/models/printing_models.dart';
import '../../data/models/sales_models.dart';
import '../../data/models/payment_models.dart';
import 'esc_pos_generator.dart';

/// 🖨️ Servicio de generación de tickets
class PrintTicketService {
  /// Generar comanda de cocina
  static PrintTicket generateKitchenTicket({
    required Order order,
    required List<OrderItem> items,
    required String tableName,
    String? waiterName,
    String? businessName,
  }) {
    final gen = EscPosGenerator(paperWidth: 80);

    // Header simple para cocina
    gen.initialize();
    gen.lineFeed();

    if (businessName != null) {
      gen.setTextSize(width: 2, height: 2);
      gen.setBold(true);
      gen.textCentered(businessName);
      gen.setBold(false);
      gen.setTextSize();
    }

    gen.lineFeed();
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered('COMANDA DE COCINA');
    gen.setBold(false);
    gen.setTextSize();
    gen.doubleSeparator();

    // Información de orden
    gen.orderInfo(
      orderNumber: order.id.substring(0, 8).toUpperCase(),
      tableName: tableName,
      dateTime: order.createdAt,
      waiterName: waiterName,
    );

    // Items
    for (final item in items) {
      gen.lineFeed();
      gen.setTextSize(width: 2, height: 2);
      gen.setBold(true);
      gen.text('x${item.quantity.toInt()} ${item.productName}');
      gen.setBold(false);
      gen.setTextSize();

      // Modificadores
      if (item.modifiers.isNotEmpty) {
        for (final mod in item.modifiers) {
          gen.text('  + ${mod.name}');
        }
      }

      // Notas
      if (item.notes != null && item.notes!.isNotEmpty) {
        gen.lineFeed();
        gen.setBold(true);
        gen.text('NOTA: ${item.notes}');
        gen.setBold(false);
      }

      gen.separator();
    }

    gen.lineFeed(3);
    gen.cut();

    return PrintTicket(
      type: 'kitchen_order',
      escPosCommands: gen.getCommands(),
    );
  }

  /// Generar precuenta - DISEÑO PROFESIONAL CON PUNTOS EN LÍNEA
  static PrintTicket generatePrecheck({
    required Order order,
    required List<OrderItem> items,
    required String tableName,
    String? waiterName,
    String? businessName,
    String? businessAddress,
    String? businessPhone,
  }) {
    final gen = EscPosGenerator(paperWidth: 80);

    gen.initialize();
    gen.lineFeed(2);

    // ════════════════════════════════════════════
    // HEADER - Nombre del negocio
    // ════════════════════════════════════════════
    if (businessName != null && businessName.isNotEmpty) {
      gen.setTextSize(width: 2, height: 2);
      gen.setBold(true);
      gen.textCentered(businessName.toUpperCase());
      gen.setBold(false);
      gen.setTextSize();
    }

    // Info de contacto centrada
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
    gen.textCentered('PRECUENTA');
    gen.setBold(false);
    gen.setTextSize();

    gen.lineFeed();
    _thickSeparator(gen);
    gen.lineFeed();

    // ════════════════════════════════════════════
    // INFORMACIÓN DE LA ORDEN
    // ════════════════════════════════════════════
    gen.setBold(true);
    gen.textRow('Orden:', order.id.substring(0, 8).toUpperCase());
    gen.setBold(false);

    if (tableName.isNotEmpty) {
      gen.textRow('Mesa:', tableName);
    }
    gen.textRow('Fecha:', _formatDateTime(order.createdAt));

    if (waiterName != null && waiterName.isNotEmpty) {
      gen.textRow('Mesero:', waiterName);
    }

    gen.lineFeed();
    _thinSeparator(gen);
    gen.lineFeed();

    // ════════════════════════════════════════════
    // ITEMS - PRODUCTOS (TAMAÑO PEQUEÑO + PUNTOS EN MÍSMA LÍNEA)
    // ════════════════════════════════════════════
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final unitPrice = item.total / item.quantity;

      // Nombre del producto (tamaño normal, negrita)
      gen.setTextSize(); // tamaño normal para items
      gen.setBold(true);
      gen.text(item.productName);
      gen.setBold(false);

      // Cantidad x precio ......... TOTAL (puntos pegados)
      final leftPart =
          '${item.quantity.toInt()} x RD\$ ${unitPrice.toStringAsFixed(2)}';
      gen.textRow(
        '$leftPart ..........', // puntos van en misma línea
        'RD\$ ${item.total.toStringAsFixed(2)}',
      );

      // Modificadores con indentación y bullet
      if (item.modifiers.isNotEmpty) {
        for (final mod in item.modifiers) {
          gen.text('  · ${mod.name}');
        }
      }

      // Notas especiales destacadas
      if (item.notes != null && item.notes!.isNotEmpty) {
        gen.setBold(true);
        gen.text('  Nota: ${item.notes}');
        gen.setBold(false);
      }

      // Separador visual suave entre items (excepto último)
      if (i < items.length - 1) {
        gen.lineFeed();
        gen.text('.........................');
        gen.lineFeed();
      }
    }

    gen.lineFeed();
    _thinSeparator(gen);
    gen.lineFeed();

    // ════════════════════════════════════════════
    // TOTALES (TAMAÑO NORMAL)
    // ════════════════════════════════════════════

    gen.setTextSize(); // totales en tamaño normal

    // Subtotal
    gen.textRow('Subtotal:', 'RD\$ ${order.subtotal.toStringAsFixed(2)}');

    // Descuentos
    if (order.discounts > 0) {
      gen.textRow('Descuento:', '-RD\$ ${order.discounts.toStringAsFixed(2)}');
    }

    // Cargo por servicio
    if (order.serviceFee > 0) {
      final servicePct = ((order.serviceFee / order.subtotal) * 100)
          .toStringAsFixed(0);
      gen.textRow(
        'Servicio ($servicePct%):',
        'RD\$ ${order.serviceFee.toStringAsFixed(2)}',
      );
    }

    // ITBIS
    gen.textRow('ITBIS (18%):', 'RD\$ ${order.tax.toStringAsFixed(2)}');

    gen.lineFeed();
    _thickSeparator(gen);
    gen.lineFeed();

    // TOTAL - Solo aquí tamaño 2x para resaltar
    gen.setBold(true);
    gen.setTextSize(width: 2, height: 2);
    gen.textRow('TOTAL:', 'RD\$ ${order.total.toStringAsFixed(2)}');
    gen.setTextSize(); // regresamos a normal
    gen.setBold(false);

    gen.lineFeed();
    _thickSeparator(gen);

    // ════════════════════════════════════════════
    // FOOTER
    // ════════════════════════════════════════════
    gen.lineFeed(2);
    gen.setBold(true);
    gen.textCentered('ESTE DOCUMENTO ES SOLO');
    gen.textCentered('UNA PRECUENTA');
    gen.setBold(false);

    gen.lineFeed();
    _thinSeparator(gen);
    gen.lineFeed();

    gen.textCentered('Gracias por su preferencia');
    gen.textCentered('Por favor verifique los datos');
    gen.lineFeed(3);

    gen.cut();

    return PrintTicket(type: 'precheck', escPosCommands: gen.getCommands());
  }

  /// Generar factura fiscal
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

    // Header
    gen.ticketHeader(
      businessName: businessName,
      address: businessAddress,
      phone: businessPhone,
      rnc: businessRnc,
    );

    // Tipo de documento
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered('FACTURA');
    gen.setBold(false);
    gen.setTextSize();
    gen.separator();

    // Información fiscal
    gen.fiscalInfo(
      ncf: fiscalDoc.ncfNumber,
      ncfType: _getNcfTypeName(fiscalDoc.ncfType),
      customerName: fiscalDoc.customerName,
      customerRnc: fiscalDoc.customerRnc,
    );

    // Información de orden
    gen.orderInfo(
      orderNumber: order.id.substring(0, 8).toUpperCase(),
      tableName: tableName ?? 'N/A',
      dateTime: fiscalDoc.issuedAt,
      waiterName: waiterName,
    );

    // Items
    for (final item in items) {
      gen.orderItem(
        name: item.productName,
        quantity: item.quantity,
        price: item.total,
        modifiers: item.modifiers.map((m) => m.name).toList(),
      );
    }

    // Totales
    gen.totals(
      subtotal: order.subtotal,
      discounts: order.discounts > 0 ? order.discounts : null,
      serviceFee: order.serviceFee > 0 ? order.serviceFee : null,
      tax: order.tax,
      total: order.total,
    );

    // Información de pago
    gen.paymentInfo(
      method: paymentMethod.name,
      amount: payment.amount,
      change: payment.changeAmount > 0 ? payment.changeAmount : null,
      reference: payment.reference,
    );

    // Footer
    gen.ticketFooter();

    gen.cut();

    return PrintTicket(
      type: 'fiscal_invoice',
      escPosCommands: gen.getCommands(),
    );
  }

  /// Generar ticket de cierre de caja
  static PrintTicket generateCashCloseTicket({
    required CashRegisterSession session,
    required Map<String, double> summary,
    required String businessName,
    String? cashierName,
  }) {
    final gen = EscPosGenerator(paperWidth: 80);

    // Header
    gen.initialize();
    gen.lineFeed();
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(businessName);
    gen.setBold(false);
    gen.setTextSize();
    gen.lineFeed();
    gen.doubleSeparator();

    // Tipo de documento
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered('CIERRE DE CAJA');
    gen.setBold(false);
    gen.setTextSize();
    gen.separator();

    // Información de sesión
    gen.text('Sesión: ${session.id.substring(0, 8).toUpperCase()}');
    if (cashierName != null) gen.text('Cajero: $cashierName');
    gen.text('Apertura: ${_formatDateTime(session.openedAt)}');
    if (session.closedAt != null) {
      gen.text('Cierre: ${_formatDateTime(session.closedAt!)}');
    }
    gen.separator();

    // Resumen
    gen.lineFeed();
    gen.setBold(true);
    gen.text('RESUMEN DE EFECTIVO:');
    gen.setBold(false);
    gen.lineFeed();

    gen.textRow(
      'Monto inicial:',
      'RD\$ ${summary['start_amount']!.toStringAsFixed(2)}',
    );
    gen.textRow('Ventas:', 'RD\$ ${summary['sales']!.toStringAsFixed(2)}');
    gen.textRow(
      'Depósitos:',
      'RD\$ ${summary['deposits']!.toStringAsFixed(2)}',
    );
    gen.textRow('Gastos:', '-RD\$ ${summary['expenses']!.toStringAsFixed(2)}');
    gen.textRow(
      'Retiros:',
      '-RD\$ ${summary['withdrawals']!.toStringAsFixed(2)}',
    );

    gen.doubleSeparator();

    gen.setBold(true);
    gen.setTextSize(width: 2, height: 2);
    gen.textRow(
      'ESPERADO:',
      'RD\$ ${summary['expected_cash']!.toStringAsFixed(2)}',
    );
    gen.setTextSize();
    gen.setBold(false);

    if (session.endAmount != null) {
      gen.lineFeed();
      gen.textRow('Contado:', 'RD\$ ${session.endAmount!.toStringAsFixed(2)}');

      final diff = session.endAmount! - summary['expected_cash']!;
      if (diff != 0) {
        gen.setBold(true);
        gen.textRow(
          'Diferencia:',
          '${diff > 0 ? '+' : ''}RD\$ ${diff.toStringAsFixed(2)}',
        );
        gen.setBold(false);
      }
    }

    gen.lineFeed(3);
    gen.cut();

    return PrintTicket(type: 'cash_close', escPosCommands: gen.getCommands());
  }

  // ════════════════════════════════════════════
  // 🔧 UTILIDADES
  // ════════════════════════════════════════════

  static String _getNcfTypeName(String code) {
    switch (code) {
      case 'B01':
        return 'Crédito Fiscal';
      case 'B02':
        return 'Consumidor Final';
      case 'B14':
        return 'Régimen Especial';
      case 'B15':
        return 'Gubernamental';
      default:
        return code;
    }
  }

  static String _formatDateTime(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  static void _thinSeparator(EscPosGenerator gen) {
    gen.textCentered('--------------------------------');
  }

  static void _thickSeparator(EscPosGenerator gen) {
    gen.textCentered('================================');
  }
}
