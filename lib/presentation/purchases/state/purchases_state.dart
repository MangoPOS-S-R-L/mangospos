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
  final String unit;
  final double cost;
  final bool isActive;

  const PurchaseInventoryItem({
    required this.id,
    required this.name,
    required this.sku,
    required this.unit,
    required this.cost,
    required this.isActive,
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
      status: map['status']?.toString() ?? 'draft',
      total: toDouble(map['total']),
      notes: map['notes']?.toString() ?? '',
      expectedDate: parseDate(map['expected_date']),
      receivedDate: parseDate(map['received_date']),
      createdAt: parseDate(map['created_at']) ?? DateTime.now(),
    );
  }
}

class PurchaseDraftItem {
  final String? inventoryItemId;
  final String description;
  final double quantity;
  final double unitCost;
  final double taxRate;

  const PurchaseDraftItem({
    this.inventoryItemId,
    required this.description,
    required this.quantity,
    required this.unitCost,
    this.taxRate = 18,
  });

  double get total => quantity * unitCost;
}

class PurchasesState {
  final bool loading;
  final bool saving;
  final String? error;
  final String? businessId;
  final String? selectedStatus;
  final List<PurchaseSupplier> suppliers;
  final List<PurchaseWarehouse> warehouses;
  final List<PurchaseInventoryItem> inventoryItems;
  final List<PurchaseOrderSummary> orders;
  final Map<String, double> totalsByStatus;

  const PurchasesState({
    this.loading = false,
    this.saving = false,
    this.error,
    this.businessId,
    this.selectedStatus,
    this.suppliers = const [],
    this.warehouses = const [],
    this.inventoryItems = const [],
    this.orders = const [],
    this.totalsByStatus = const {},
  });

  PurchasesState copyWith({
    bool? loading,
    bool? saving,
    String? error,
    String? businessId,
    String? selectedStatus,
    List<PurchaseSupplier>? suppliers,
    List<PurchaseWarehouse>? warehouses,
    List<PurchaseInventoryItem>? inventoryItems,
    List<PurchaseOrderSummary>? orders,
    Map<String, double>? totalsByStatus,
    bool clearError = false,
  }) {
    return PurchasesState(
      loading: loading ?? this.loading,
      saving: saving ?? this.saving,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      selectedStatus: selectedStatus ?? this.selectedStatus,
      suppliers: suppliers ?? this.suppliers,
      warehouses: warehouses ?? this.warehouses,
      inventoryItems: inventoryItems ?? this.inventoryItems,
      orders: orders ?? this.orders,
      totalsByStatus: totalsByStatus ?? this.totalsByStatus,
    );
  }
}
