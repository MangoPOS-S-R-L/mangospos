class PurchaseSupplier {
  final String id;
  final String name;
  final String contactName;
  final String phone;
  final String email;
  final bool isActive;

  const PurchaseSupplier({
    required this.id,
    required this.name,
    required this.contactName,
    required this.phone,
    required this.email,
    required this.isActive,
  });

  factory PurchaseSupplier.fromMap(Map<String, dynamic> map) {
    return PurchaseSupplier(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Proveedor',
      contactName: map['contact_name']?.toString() ?? '',
      phone: map['phone']?.toString() ?? '',
      email: map['email']?.toString() ?? '',
      isActive: map['is_active'] != false,
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
    this.purchaseUnit = '',
    this.packSize = 1,
  });

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
      purchaseUnit: map['purchase_unit']?.toString() ?? '',
      packSize: () {
        final v = toDouble(map['pack_size']);
        return v <= 0 ? 1.0 : v;
      }(),
    );
  }
}

class PurchaseOrderSummary {
  final String id;
  final String supplierId;
  final String supplierName;
  final String warehouseId;
  final String warehouseName;
  final String orderNumber;
  /// Número de factura/NCF físico del proveedor (distinto del folio interno).
  final String invoiceNumber;
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
    required this.status,
    required this.total,
    required this.notes,
    required this.expectedDate,
    required this.receivedDate,
    required this.createdAt,
  });

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
    this.purchaseUnit = '',
    this.packSize = 1,
  });

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
