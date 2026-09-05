class PurchaseSupplier {
  final String id;
  final String name;
  final String contactName;
  final String phone;
  final String email;
  final bool isActive;
  /// Condiciones de pago tal como las escribió el negocio («30 días»,
  /// «contado», «50% anticipo»). Se muestran literales; no se interpretan.
  final String paymentTerms;
  /// Días de plazo (mig 20260814_0003). Cuando existe, alimenta el
  /// vencimiento por defecto de la cuenta por pagar. `null` = sin dato.
  final int? paymentTermsDays;

  const PurchaseSupplier({
    required this.id,
    required this.name,
    required this.contactName,
    required this.phone,
    required this.email,
    required this.isActive,
    this.paymentTerms = '',
    this.paymentTermsDays,
  });

  factory PurchaseSupplier.fromMap(Map<String, dynamic> map) {
    return PurchaseSupplier(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Proveedor',
      contactName: map['contact_name']?.toString() ?? '',
      phone: map['phone']?.toString() ?? '',
      email: map['email']?.toString() ?? '',
      isActive: map['is_active'] != false,
      paymentTerms: map['payment_terms']?.toString() ?? '',
      paymentTermsDays: () {
        final raw = map['payment_terms_days'];
        if (raw is num) return raw.toInt();
        return int.tryParse(raw?.toString() ?? '');
      }(),
    );
  }
}

class PurchaseWarehouse {
  final String id;
  final String name;
  final bool isMain;

  const PurchaseWarehouse({
    required this.id,
    required this.name,
    required this.isMain,
  });

  factory PurchaseWarehouse.fromMap(Map<String, dynamic> map) {
    return PurchaseWarehouse(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Almacen',
      isMain: map['is_main'] == true,
    );
  }
}

class PurchaseInventoryItem {
  final String id;
  final String name;
  final String sku;
  final String unit; // unidad BASE de stock
  final double cost;
  final bool isActive;
  /// Código de barras del insumo. La columna ya existía; el buscador del
  /// registro de compra no la consultaba (solo nombre y SKU).
  final String barcode;
  // Conversión de empaque: se compra en purchaseUnit (ej. botella) que
  // contiene packSize unidades base (ej. 750 ml). '' / 1 = sin empaque.
  final String purchaseUnit;
  final double packSize;

  const PurchaseInventoryItem({
    required this.id,
    required this.name,
    required this.sku,
    required this.unit,
    required this.cost,
    required this.isActive,
    this.barcode = '',
    this.purchaseUnit = '',
    this.packSize = 1,
  });

  /// Criterio ÚNICO del buscador manual del registro de compra: nombre, SKU o
  /// código de barras. Escanear y teclear tienen que resolver igual, así que
  /// el código completo escrito a mano encuentra el insumo lo mismo que la
  /// pistola.
  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return false;
    return name.toLowerCase().contains(q) ||
        sku.toLowerCase().contains(q) ||
        barcode.toLowerCase().contains(q);
  }

  /// Coincidencia EXACTA por código de barras o SKU, en ese orden de
  /// prioridad — es lo que resuelve un escaneo (§5.2 del PRD).
  bool matchesCode(String code) {
    final c = code.trim().toLowerCase();
    if (c.isEmpty) return false;
    return barcode.trim().toLowerCase() == c || sku.trim().toLowerCase() == c;
  }

  factory PurchaseInventoryItem.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    return PurchaseInventoryItem(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Insumo',
      sku: map['sku']?.toString() ?? '',
      unit: map['unit']?.toString() ?? 'unidad',
      cost: toDouble(map['cost']),
      isActive: map['is_active'] != false,
      barcode: map['barcode']?.toString() ?? '',
      purchaseUnit: map['purchase_unit']?.toString() ?? '',
      packSize: () {
        final v = toDouble(map['pack_size']);
        return v <= 0 ? 1.0 : v;
      }(),
    );
  }
}

/// Marca que se deja en las notas de la orden cuando la compra se registró a
/// crédito pero la cuenta por pagar NO llegó a nacer (§6.4 del PRD).
///
/// Mientras la orden y la CxP no se guarden como una sola operación atómica
/// (F6), ese estado partido —mercancía ingresada, deuda sin registrar— tiene
/// que ser VISIBLE en el listado y no un aviso que desaparece a los dos
/// segundos: solo se descubre cuando el proveedor viene a cobrar.
const kPendingPayableTag = '[CxP pendiente de registrar]';

class PurchaseOrderSummary {
  final String id;
  final String supplierId;
  final String supplierName;
  final String warehouseId;
  final String warehouseName;
  final String orderNumber;
  /// Número propio de la factura del proveedor — el identificador con el que
  /// se le reclama. El comprobante fiscal viaja aparte, en [ncf].
  final String invoiceNumber;
  /// Comprobante fiscal (NCF/e-CF) de la factura. Vacío es legítimo.
  final String ncf;
  final String status;
  final double total;
  final String notes;
  final DateTime? expectedDate;
  final DateTime? receivedDate;
  final DateTime createdAt;

  const PurchaseOrderSummary({
    required this.id,
    required this.supplierId,
    required this.supplierName,
    required this.warehouseId,
    required this.warehouseName,
    required this.orderNumber,
    required this.invoiceNumber,
    this.ncf = '',
    required this.status,
    required this.total,
    required this.notes,
    required this.expectedDate,
    required this.receivedDate,
    required this.createdAt,
  });

  /// La compra se guardó a crédito pero la deuda no quedó registrada.
  bool get payablePending => notes.contains(kPendingPayableTag);

  factory PurchaseOrderSummary.fromMap(
    Map<String, dynamic> map, {
    required String supplierName,
    required String warehouseName,
  }) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      return DateTime.tryParse(value.toString());
    }

    return PurchaseOrderSummary(
      id: map['id']?.toString() ?? '',
      supplierId: map['supplier_id']?.toString() ?? '',
      supplierName: supplierName,
      warehouseId: map['warehouse_id']?.toString() ?? '',
      warehouseName: warehouseName,
      orderNumber: map['order_number']?.toString() ?? 'PO-00000',
      invoiceNumber: map['invoice_number']?.toString() ?? '',
      ncf: map['ncf']?.toString() ?? '',
      status: map['status']?.toString() ?? 'draft',
      total: toDouble(map['total']),
      notes: map['notes']?.toString() ?? '',
      expectedDate: parseDate(map['expected_date']),
      receivedDate: parseDate(map['received_date']),
      createdAt: parseDate(map['created_at']) ?? DateTime.now(),
    );
  }
}

/// Línea de una orden de compra existente: combina cantidades pedidas vs
/// recibidas con datos descriptivos del insumo (cuando la línea está vinculada).
/// Sprint 3 — recepción parcial.
class PurchaseOrderLine {
  final String id;
  final String? inventoryItemId;
  final String description;
  final String itemName;
  final String unit; // unidad BASE (las cantidades de la línea están en base)
  final String sku;
  final bool tracksLots;
  final double quantityOrdered;
  final double quantityReceived;
  final double unitCost;
  final double taxRate;
  final double total;
  /// Descuento del proveedor en la LÍNEA, en RD$ NETO (sin ITBIS). Es
  /// informativo: `unitCost` ya viene descontado. Sirve para reconstruir el
  /// precio de lista en el detalle de la factura. La columna llega con la
  /// migración 20260725_0001; sin ella la lectura cae a 0.
  final double discount;
  // Snapshot de empaque al crear la orden (para mostrar/recibir en la
  // unidad de compra). purchaseUnit vacío / packSize 1 = sin empaque.
  final String purchaseUnit;
  final double packSize;

  const PurchaseOrderLine({
    required this.id,
    required this.inventoryItemId,
    required this.description,
    required this.itemName,
    required this.unit,
    required this.sku,
    required this.tracksLots,
    required this.quantityOrdered,
    required this.quantityReceived,
    required this.unitCost,
    required this.taxRate,
    required this.total,
    this.discount = 0,
    this.purchaseUnit = '',
    this.packSize = 1,
  });

  /// Base NETA de la línea (sin ITBIS), tal como se guardó.
  double get netTotal => total;

  /// ITBIS de la línea en dinero. `tax_rate` se guarda como tasa EFECTIVA
  /// (el registro la deriva del ITBIS absoluto digitado), así que el
  /// porcentaje reconstruye el monto exacto que se pagó.
  double get taxValue => total * taxRate / 100;

  /// Total de la línea con ITBIS.
  double get grossTotal => netTotal + taxValue;

  /// Precio de lista por unidad, antes del descuento del proveedor. Sin
  /// descuento (o sin cantidad) es el propio [unitCost].
  double get listUnitCost {
    if (discount <= 0 || quantityOrdered <= 0) return unitCost;
    return (total + discount) / quantityOrdered;
  }

  double get pending =>
      (quantityOrdered - quantityReceived).clamp(0, double.infinity);

  bool get isFulfilled => pending == 0;

  /// Las líneas sin `inventoryItemId` no generan movimientos de stock; se
  /// reciben "lógicamente" para cerrar la orden pero no impactan inventario.
  bool get tracksInventory => inventoryItemId != null;

  factory PurchaseOrderLine.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    final itemRel = map['inventory_items'];
    final itemName = itemRel is Map
        ? (itemRel['name']?.toString() ?? map['description']?.toString() ?? '—')
        : (map['description']?.toString() ?? '—');
    final unit = itemRel is Map
        ? (itemRel['unit']?.toString() ?? 'unidad')
        : 'unidad';
    final sku = itemRel is Map ? (itemRel['sku']?.toString() ?? '') : '';
    final tracksLots = itemRel is Map ? (itemRel['tracks_lots'] == true) : false;

    return PurchaseOrderLine(
      id: map['id']?.toString() ?? '',
      inventoryItemId: map['inventory_item_id']?.toString(),
      description: map['description']?.toString() ?? '',
      itemName: itemName,
      unit: unit,
      sku: sku,
      tracksLots: tracksLots,
      quantityOrdered: toDouble(map['quantity_ordered']),
      quantityReceived: toDouble(map['quantity_received']),
      unitCost: toDouble(map['unit_cost']),
      taxRate: toDouble(map['tax_rate']),
      total: toDouble(map['total']),
      discount: toDouble(map['discount']),
      // Snapshot guardado en la línea; si falta, cae al del insumo vinculado.
      purchaseUnit: (map['purchase_unit'] ??
              (itemRel is Map ? itemRel['purchase_unit'] : null))
          ?.toString() ??
          '',
      packSize: () {
        final raw = map['pack_size'] ??
            (itemRel is Map ? itemRel['pack_size'] : null);
        final v = toDouble(raw);
        return v <= 0 ? 1.0 : v;
      }(),
    );
  }
}

/// Factura de compra COMPLETA: la cabecera guardada (con su desglose) más
/// las líneas de lo que se compró.
///
/// El listado solo trae el total; para revisar una factura contra el papel
/// del proveedor hace falta el desglose que la orden guardó —subtotal, ITBIS
/// y descuento global— y el detalle de cada producto.
class PurchaseOrderDetail {
  final PurchaseOrderSummary order;

  /// Base NETA guardada en la cabecera (sin ITBIS).
  final double subtotal;

  /// ITBIS guardado en la cabecera.
  final double tax;

  /// Descuento GLOBAL de la orden en RD$ (pronto pago, acuerdo comercial).
  /// No se prorratea a las líneas. 0 cuando la migración 20260725_0001 no
  /// está aplicada: la columna no existe y no se puede inventar.
  final double discount;

  final List<PurchaseOrderLine> lines;

  /// Quién REGISTRÓ la compra (`purchase_orders.created_by` resuelto a
  /// nombre de empleado). Va en la firma «Realizado por» del documento
  /// impreso. Vacío cuando el usuario no tiene ficha de empleado: el papel
  /// sale igual, con la raya en blanco.
  final String createdByName;

  const PurchaseOrderDetail({
    required this.order,
    required this.subtotal,
    required this.tax,
    required this.discount,
    required this.lines,
    this.createdByName = '',
  });

  /// Suma de los descuentos POR LÍNEA (informativo: los costos ya vienen
  /// descontados, así que esto no se resta otra vez del total).
  double get lineDiscounts =>
      lines.fold<double>(0, (sum, line) => sum + line.discount);

  /// Lo que suman las líneas con su ITBIS. Puede diferir del total guardado
  /// en órdenes viejas o creadas por otros flujos; la vista lo avisa en vez
  /// de tapar la diferencia.
  double get linesGrossTotal =>
      lines.fold<double>(0, (sum, line) => sum + line.grossTotal);

  /// Diferencia entre lo que suman las líneas y el total guardado, ya
  /// descontado el descuento global. Cero (± 1 centavo) = todo cuadra.
  double get totalsMismatch => linesGrossTotal - discount - order.total;

  bool get totalsAgree => totalsMismatch.abs() < 0.01;
}

class PurchaseDraftItem {
  final String? inventoryItemId;
  final String description;
  /// Cantidad y costo YA en unidad BASE (la vista convirtió desde la unidad
  /// de compra antes de crear el draft). `unitCost` es el costo NETO (sin
  /// ITBIS): así queda el costo maestro del insumo y el movimiento de stock.
  final double quantity;
  final double unitCost;
  final double taxRate;
  /// ITBIS ABSOLUTO de la línea (en dinero). Cuando es null, el impuesto se
  /// deriva del porcentaje (`total * taxRate / 100`), modo heredado usado por
  /// las OC generadas desde sugerencias de reorden.
  final double? taxAmount;
  /// Descuento del proveedor en la LÍNEA, en RD$ NETO (sin ITBIS),
  /// informativo: `unitCost` ya viene descontado (costo real pagado), así el
  /// costo maestro y el kardex quedan correctos sin cambios de servidor. El
  /// precio original se reconstruye: (quantity*unitCost + discountAmount)/quantity.
  final double discountAmount;
  // Snapshot de empaque para guardar en la línea (display/recepción).
  final String purchaseUnit;
  final double packSize;

  const PurchaseDraftItem({
    this.inventoryItemId,
    required this.description,
    required this.quantity,
    required this.unitCost,
    this.taxRate = 18,
    this.taxAmount,
    this.discountAmount = 0,
    this.purchaseUnit = '',
    this.packSize = 1,
  });

  /// Base NETA de la línea (sin ITBIS).
  double get total => quantity * unitCost;

  /// ITBIS de la línea: absoluto si viene dado, si no derivado del porcentaje.
  double get taxValue => taxAmount ?? (total * taxRate / 100);
}

class PurchasesState {
  /// Tamaño de página para la lista de órdenes de compra.
  static const ordersPageSize = 50;

  final bool loading;
  final bool ordersLoadingMore;
  final bool saving;
  final String? error;
  final String? businessId;
  final String? selectedStatus;
  final List<PurchaseSupplier> suppliers;
  final List<PurchaseWarehouse> warehouses;
  final List<PurchaseInventoryItem> inventoryItems;
  final List<PurchaseOrderSummary> orders;
  final bool ordersHasMore;
  final Map<String, double> totalsByStatus;

  const PurchasesState({
    this.loading = false,
    this.ordersLoadingMore = false,
    this.saving = false,
    this.error,
    this.businessId,
    this.selectedStatus,
    this.suppliers = const [],
    this.warehouses = const [],
    this.inventoryItems = const [],
    this.orders = const [],
    this.ordersHasMore = false,
    this.totalsByStatus = const {},
  });

  PurchasesState copyWith({
    bool? loading,
    bool? ordersLoadingMore,
    bool? saving,
    String? error,
    String? businessId,
    String? selectedStatus,
    List<PurchaseSupplier>? suppliers,
    List<PurchaseWarehouse>? warehouses,
    List<PurchaseInventoryItem>? inventoryItems,
    List<PurchaseOrderSummary>? orders,
    bool? ordersHasMore,
    Map<String, double>? totalsByStatus,
    bool clearError = false,
  }) {
    return PurchasesState(
      loading: loading ?? this.loading,
      ordersLoadingMore: ordersLoadingMore ?? this.ordersLoadingMore,
      saving: saving ?? this.saving,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      selectedStatus: selectedStatus ?? this.selectedStatus,
      suppliers: suppliers ?? this.suppliers,
      warehouses: warehouses ?? this.warehouses,
      inventoryItems: inventoryItems ?? this.inventoryItems,
      orders: orders ?? this.orders,
      ordersHasMore: ordersHasMore ?? this.ordersHasMore,
      totalsByStatus: totalsByStatus ?? this.totalsByStatus,
    );
  }
}
