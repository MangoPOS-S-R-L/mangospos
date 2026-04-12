import 'package:equatable/equatable.dart';

/// 🧾 Sesión de mesa
class TableSession extends Equatable {
  final String id;
  final String? tableId;
  final String businessId;
  final String openedBy;
  final String? waiterUserId;
  final DateTime openedAt;
  final DateTime? closedAt;
  final String? customerName;
  final String? note;
  final String
  origin; // 'dine_in', 'manual', 'quick_sale', 'delivery', 'self_service'
  final int peopleCount;
  final String? tableName;
  final String? zoneName;

  const TableSession({
    required this.id,
    this.tableId,
    required this.businessId,
    required this.openedBy,
    this.waiterUserId,
    required this.openedAt,
    this.closedAt,
    this.customerName,
    this.note,
    required this.origin,
    required this.peopleCount,
    this.tableName,
    this.zoneName,
  });

  factory TableSession.fromMap(Map<String, dynamic> map) {
    return TableSession(
      id: map['id'] ?? '',
      tableId: map['table_id'],
      businessId: map['business_id'] ?? '',
      openedBy: map['opened_by'] ?? '',
      waiterUserId: map['waiter_user_id'],
      openedAt: DateTime.tryParse(map['opened_at'] ?? '') ?? DateTime.now(),
      closedAt: map['closed_at'] != null
          ? DateTime.tryParse(map['closed_at'])
          : null,
      customerName: map['customer_name'],
      note: map['note'],
      origin: map['origin'] ?? 'dine_in',
      peopleCount: map['people_count'] ?? 1,
      tableName: map['dining_tables'] != null
          ? map['dining_tables']['code']
          : map['table_name'],
      zoneName:
          map['dining_tables'] != null && map['dining_tables']['zones'] != null
          ? map['dining_tables']['zones']['name']
          : map['zone_name'],
    );
  }

  bool get isActive => closedAt == null;

  @override
  List<Object?> get props => [
    id,
    tableId,
    businessId,
    openedBy,
    waiterUserId,
    openedAt,
    closedAt,
    customerName,
    note,
    origin,
    peopleCount,
    tableName,
    zoneName,
  ];
}

/// 📦 Orden completa (actualizada)
class Order extends Equatable {
  final String id;
  final String sessionId;
  final String status;
  final double subtotal;
  final double discounts;
  final double serviceFee;
  final double tax;
  final double total;
  final DateTime createdAt;
  final DateTime? closedAt;

  const Order({
    required this.id,
    required this.sessionId,
    required this.status,
    required this.subtotal,
    required this.discounts,
    required this.serviceFee,
    required this.tax,
    required this.total,
    required this.createdAt,
    this.closedAt,
  });

  factory Order.fromMap(Map<String, dynamic> map) {
    return Order(
      id: map['id'] ?? '',
      sessionId: map['session_id'] ?? '',
      status: map['status_ext'] ?? 'open',
      subtotal: (map['subtotal'] ?? 0).toDouble(),
      discounts: (map['discounts'] ?? 0).toDouble(),
      serviceFee: (map['service_fee'] ?? 0).toDouble(),
      tax: (map['tax'] ?? 0).toDouble(),
      total: (map['total'] ?? 0).toDouble(),
      createdAt: DateTime.tryParse(map['created_at'] ?? '') ?? DateTime.now(),
      closedAt: map['closed_at'] != null
          ? DateTime.tryParse(map['closed_at'])
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'session_id': sessionId,
    'status_ext': status,
    'subtotal': subtotal,
    'discounts': discounts,
    'service_fee': serviceFee,
    'tax': tax,
    'total': total,
    'created_at': createdAt.toIso8601String(),
    'closed_at': closedAt?.toIso8601String(),
  };

  Order copyWith({
    String? id,
    String? sessionId,
    String? status,
    double? subtotal,
    double? discounts,
    double? serviceFee,
    double? tax,
    double? total,
    DateTime? createdAt,
    DateTime? closedAt,
  }) {
    return Order(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      status: status ?? this.status,
      subtotal: subtotal ?? this.subtotal,
      discounts: discounts ?? this.discounts,
      serviceFee: serviceFee ?? this.serviceFee,
      tax: tax ?? this.tax,
      total: total ?? this.total,
      createdAt: createdAt ?? this.createdAt,
      closedAt: closedAt ?? this.closedAt,
    );
  }

  bool get isOpen => status == 'open' || status == 'draft';
  bool get isSent => status == 'sent' || status == 'preparing';
  bool get isPaid => status == 'paid';
  bool get isCancelled => status == 'cancelled';

  @override
  List<Object?> get props => [
    id,
    sessionId,
    status,
    subtotal,
    discounts,
    serviceFee,
    tax,
    total,
    createdAt,
    closedAt,
  ];
}

/// 🍔 Item de orden con modificadores
class OrderItem extends Equatable {
  final String id;
  final String orderId;
  final String? productId;
  final String productName;
  final String? sku;
  final double quantity;
  final double unitPrice;
  final double subtotal;
  final double discounts;
  final double tax;
  final double total;
  final String? checkId;
  final bool isTakeout;
  final String status; // 'draft', 'pending', 'preparing', 'ready', 'served'
  final String? notes;
  final String taxMode;
  final double taxRate;
  final double? originalTaxRate;
  final String? printAreaCode;
  final DateTime createdAt;
  final List<OrderItemModifier> modifiers;

  const OrderItem({
    required this.id,
    required this.orderId,
    this.productId,
    required this.productName,
    this.sku,
    required this.quantity,
    required this.unitPrice,
    required this.subtotal,
    required this.discounts,
    required this.tax,
    required this.total,
    this.checkId,
    required this.isTakeout,
    required this.status,
    this.notes,
    this.taxMode = 'exclusive',
    this.taxRate = 0.0,
    this.originalTaxRate,
    this.printAreaCode,
    required this.createdAt,
    this.modifiers = const [],
  });


  factory OrderItem.fromMap(Map<String, dynamic> map) {
    final rawQty = map['qty'];
    final rawQuantity = map['quantity'];
    final qtyValue = (rawQty is num)
        ? rawQty.toDouble()
        : double.tryParse(rawQty?.toString() ?? '');
    final quantityValue = (rawQuantity is num)
        ? rawQuantity.toDouble()
        : double.tryParse(rawQuantity?.toString() ?? '');

    // En algunas instalaciones quantity sigue siendo integer y puede quedar en 0
    // cuando trabajamos con fracciones; priorizamos qty si viene disponible.
    final effectiveQty = (qtyValue != null && qtyValue > 0)
        ? qtyValue
        : (quantityValue != null && quantityValue > 0)
        ? quantityValue
        : 1.0;

    final subtotal = (map['subtotal'] ?? 0).toDouble();
    final discounts = (map['discounts'] ?? 0).toDouble();
    final tax = (map['tax'] ?? 0).toDouble();
    final rawTotal = (map['total'] ?? 0).toDouble();
    final taxMode = map['tax_mode']?.toString() ?? 'exclusive';
    final derivedTotal = subtotal + tax - discounts;
    final hasBreakdown =
        subtotal.abs() > 0.0001 ||
        tax.abs() > 0.0001 ||
        discounts.abs() > 0.0001;
    final shouldPreserveRawTotal =
        rawTotal > 0 &&
        (taxMode == 'inclusive' || !hasBreakdown || derivedTotal <= 0);
    final effectiveTotal = shouldPreserveRawTotal ? rawTotal : derivedTotal;

    return OrderItem(
      id: map['id'] ?? '',
      orderId: map['order_id'] ?? '',
      productId: map['product_id'],
      productName: map['product_name'] ?? '',
      sku: map['sku'],
      quantity: effectiveQty,
      unitPrice: (map['unit_price'] ?? 0).toDouble(),
      subtotal: subtotal,
      discounts: discounts,
      tax: tax,
      total: effectiveTotal,
      checkId: map['check_id'],
      isTakeout: map['is_takeout'] ?? false,
      status: map['status'] ?? 'draft',
      notes: map['notes'],
      taxMode: taxMode,
      taxRate: (map['tax_rate'] ?? 0).toDouble(),
      originalTaxRate: (map['original_tax_rate'] ?? map['tax_rate'] ?? 0).toDouble(),
      printAreaCode: map['print_area_code'] as String?,
      createdAt: DateTime.tryParse(map['created_at'] ?? '') ?? DateTime.now(),
      modifiers: [], // Se cargan aparte
    );
  }

  OrderItem copyWith({
    String? id,
    String? orderId,
    String? productId,
    String? productName,
    String? sku,
    double? quantity,
    double? unitPrice,
    double? subtotal,
    double? discounts,
    double? tax,
    double? total,
    String? checkId,
    bool forceCheckIdNull = false,
    bool? isTakeout,
    String? status,
    String? notes,
    String? taxMode,
    double? taxRate,
    double? originalTaxRate,
    String? printAreaCode,
    DateTime? createdAt,
    List<OrderItemModifier>? modifiers,
  }) {

    return OrderItem(
      id: id ?? this.id,
      orderId: orderId ?? this.orderId,
      productId: productId ?? this.productId,
      productName: productName ?? this.productName,
      sku: sku ?? this.sku,
      quantity: quantity ?? this.quantity,
      unitPrice: unitPrice ?? this.unitPrice,
      subtotal: subtotal ?? this.subtotal,
      discounts: discounts ?? this.discounts,
      tax: tax ?? this.tax,
      total: total ?? this.total,
      checkId: forceCheckIdNull ? null : (checkId ?? this.checkId),
      isTakeout: isTakeout ?? this.isTakeout,
      status: status ?? this.status,
      notes: notes ?? this.notes,
      taxMode: taxMode ?? this.taxMode,
      taxRate: taxRate ?? this.taxRate,
      originalTaxRate: originalTaxRate ?? this.originalTaxRate,
      printAreaCode: printAreaCode ?? this.printAreaCode,
      createdAt: createdAt ?? this.createdAt,
      modifiers: modifiers ?? this.modifiers,
    );
  }

  @override
  List<Object?> get props => [
    id,
    orderId,
    productId,
    productName,
    sku,
    quantity,
    unitPrice,
    subtotal,
    discounts,
    tax,
    total,
    checkId,
    isTakeout,
    status,
    notes,
    taxMode,
    taxRate,
    originalTaxRate,
    printAreaCode,
    createdAt,
    modifiers,
  ];
}

/// 🔧 Modificador de item
class OrderItemModifier extends Equatable {
  final String id;
  final String itemId;
  final String name;
  final double qty;
  final double price;

  const OrderItemModifier({
    required this.id,
    required this.itemId,
    required this.name,
    required this.qty,
    required this.price,
  });

  factory OrderItemModifier.fromMap(Map<String, dynamic> map) {
    return OrderItemModifier(
      id: map['id'] ?? '',
      itemId: map['item_id'] ?? '',
      name: map['name'] ?? '',
      qty: (map['qty'] ?? 1).toDouble(),
      price: (map['price'] ?? 0).toDouble(),
    );
  }

  @override
  List<Object?> get props => [id, itemId, name, qty, price];
}

/// 📄 Check (subcuenta)
class OrderCheck extends Equatable {
  final String id;
  final String orderId;
  final String label;
  final int position;
  final bool isClosed;
  final double subtotal;
  final double discounts;
  final double serviceFee;
  final double tax;
  final double total;
  final String? customerId;
  final String? customerName;
  final List<OrderItem> items;

  const OrderCheck({
    required this.id,
    required this.orderId,
    required this.label,
    required this.position,
    required this.isClosed,
    required this.subtotal,
    required this.discounts,
    required this.serviceFee,
    required this.tax,
    required this.total,
    this.customerId,
    this.customerName,
    this.items = const [],
  });

  factory OrderCheck.fromMap(Map<String, dynamic> map) {
    return OrderCheck(
      id: map['id'] ?? '',
      orderId: map['order_id'] ?? '',
      label: map['label'] ?? 'C1',
      position: map['position'] ?? 1,
      isClosed: map['is_closed'] ?? false,
      subtotal: (map['subtotal'] ?? 0).toDouble(),
      discounts: (map['discounts'] ?? 0).toDouble(),
      serviceFee: (map['service_fee'] ?? 0).toDouble(),
      tax: (map['tax'] ?? 0).toDouble(),
      total: (map['total'] ?? 0).toDouble(),
      customerId: map['customer_id']?.toString(),
      customerName: map['customer_name']?.toString(),
      items: [],
    );
  }

  OrderCheck copyWith({
    String? id,
    String? orderId,
    String? label,
    int? position,
    bool? isClosed,
    double? subtotal,
    double? discounts,
    double? serviceFee,
    double? tax,
    double? total,
    String? customerId,
    String? customerName,
    bool clearCustomer = false,
    List<OrderItem>? items,
  }) {
    return OrderCheck(
      id: id ?? this.id,
      orderId: orderId ?? this.orderId,
      label: label ?? this.label,
      position: position ?? this.position,
      isClosed: isClosed ?? this.isClosed,
      subtotal: subtotal ?? this.subtotal,
      discounts: discounts ?? this.discounts,
      serviceFee: serviceFee ?? this.serviceFee,
      tax: tax ?? this.tax,
      total: total ?? this.total,
      customerId: clearCustomer ? null : (customerId ?? this.customerId),
      customerName: clearCustomer ? null : (customerName ?? this.customerName),
      items: items ?? this.items,
    );
  }

  Order toOrder({required DateTime createdAt}) {
    return Order(
      id: id,
      sessionId: orderId,
      status: isClosed ? 'closed' : 'open',
      subtotal: subtotal,
      discounts: discounts,
      serviceFee: serviceFee,
      tax: tax,
      total: total,
      createdAt: createdAt,
    );
  }

  @override
  List<Object?> get props => [
    id,
    orderId,
    label,
    position,
    isClosed,
    subtotal,
    discounts,
    serviceFee,
    tax,
    total,
    customerId,
    customerName,
    items,
  ];
}

/// 💰 Pago
class Payment extends Equatable {
  final String id;
  final String businessId;
  final String? orderId;
  final String? checkId;
  final String? fiscalDocumentId;
  final String paymentMethodId;
  final String? paymentMethodCode;
  final String? paymentMethodName;
  final double amount;
  final String? reference;
  final double changeAmount;
  final String status; // 'pending', 'completed', 'refunded', 'cancelled'
  final String? processedBy;
  final String? sessionId;
  final DateTime createdAt;

  const Payment({
    required this.id,
    required this.businessId,
    this.orderId,
    this.checkId,
    this.fiscalDocumentId,
    required this.paymentMethodId,
    this.paymentMethodCode,
    this.paymentMethodName,
    required this.amount,
    this.reference,
    required this.changeAmount,
    required this.status,
    this.processedBy,
    this.sessionId,
    required this.createdAt,
  });

  factory Payment.fromMap(Map<String, dynamic> map) {
    return Payment(
      id: map['id'] ?? '',
      businessId: map['business_id'] ?? '',
      orderId: map['order_id'],
      checkId: map['check_id'],
      fiscalDocumentId: map['fiscal_document_id'],
      paymentMethodId: map['payment_method_id'] ?? '',
      paymentMethodCode: map['payment_method_code'],
      paymentMethodName: map['payment_method_name'],
      amount: (map['amount'] ?? 0).toDouble(),
      reference: map['reference'],
      changeAmount: (map['change_amount'] ?? 0).toDouble(),
      status: map['status'] ?? 'completed',
      processedBy: map['processed_by'],
      sessionId: map['session_id'],
      createdAt: DateTime.tryParse(map['created_at'] ?? '') ?? DateTime.now(),
    );
  }

  @override
  List<Object?> get props => [
    id,
    businessId,
    orderId,
    checkId,
    fiscalDocumentId,
    paymentMethodId,
    paymentMethodCode,
    paymentMethodName,
    amount,
    reference,
    changeAmount,
    status,
    processedBy,
    sessionId,
    createdAt,
  ];

  Payment copyWith({String? paymentMethodCode, String? paymentMethodName}) {
    return Payment(
      id: id,
      businessId: businessId,
      orderId: orderId,
      checkId: checkId,
      fiscalDocumentId: fiscalDocumentId,
      paymentMethodId: paymentMethodId,
      paymentMethodCode: paymentMethodCode ?? this.paymentMethodCode,
      paymentMethodName: paymentMethodName ?? this.paymentMethodName,
      amount: amount,
      reference: reference,
      changeAmount: changeAmount,
      status: status,
      processedBy: processedBy,
      sessionId: sessionId,
      createdAt: createdAt,
    );
  }
}

/// 🧾 Documento Fiscal
class FiscalDocument extends Equatable {
  final String id;
  final String businessId;
  final String? orderId;
  final String? paymentId;
  final String? customerId;
  final String ncfType;
  final String ncfNumber;
  final String? customerRnc;
  final String customerName;
  final double subtotal;
  final double taxableAmount;
  final double itbisAmount;
  final double total;
  final String status;
  final DateTime issuedAt;

  const FiscalDocument({
    required this.id,
    required this.businessId,
    this.orderId,
    this.paymentId,
    this.customerId,
    required this.ncfType,
    required this.ncfNumber,
    this.customerRnc,
    required this.customerName,
    required this.subtotal,
    required this.taxableAmount,
    required this.itbisAmount,
    required this.total,
    required this.status,
    required this.issuedAt,
  });

  factory FiscalDocument.fromMap(Map<String, dynamic> map) {
    return FiscalDocument(
      id: map['id'] ?? '',
      businessId: map['business_id'] ?? '',
      orderId: map['order_id'],
      paymentId: map['payment_id'],
      customerId: map['customer_id'],
      ncfType: map['ncf_type'] ?? 'B02',
      ncfNumber: map['ncf_number'] ?? '',
      customerRnc: map['customer_rnc'],
      customerName: map['customer_name'] ?? 'CONSUMIDOR FINAL',
      subtotal: (map['subtotal'] ?? 0).toDouble(),
      taxableAmount: (map['taxable_amount'] ?? 0).toDouble(),
      itbisAmount: (map['itbis_amount'] ?? 0).toDouble(),
      total: (map['total'] ?? 0).toDouble(),
      status: map['status'] ?? 'active',
      issuedAt: DateTime.tryParse(map['issued_at'] ?? '') ?? DateTime.now(),
    );
  }

  @override
  List<Object?> get props => [
    id,
    businessId,
    orderId,
    paymentId,
    customerId,
    ncfType,
    ncfNumber,
    customerRnc,
    customerName,
    subtotal,
    taxableAmount,
    itbisAmount,
    total,
    status,
    issuedAt,
  ];
}
