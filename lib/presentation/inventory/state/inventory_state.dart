class InventoryWarehouse {
  final String id;
  final String name;
  final bool isMain;

  const InventoryWarehouse({
    required this.id,
    required this.name,
    required this.isMain,
  });

  factory InventoryWarehouse.fromMap(Map<String, dynamic> map) {
    return InventoryWarehouse(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Almacen',
      isMain: map['is_main'] == true,
    );
  }
}

/// PRD 9 Fase 1C — Proveedor con todos los campos del schema (`rnc`,
/// `payment_terms`, `notes`, etc.) para el CRUD del módulo Inventario.
class InventorySupplierDetail {
  final String id;
  final String name;
  final String rnc;
  final String contactName;
  final String phone;
  final String email;
  final String address;
  final String paymentTerms;
  final String notes;
  final bool isActive;
  final DateTime? createdAt;

  const InventorySupplierDetail({
    required this.id,
    required this.name,
    required this.rnc,
    required this.contactName,
    required this.phone,
    required this.email,
    required this.address,
    required this.paymentTerms,
    required this.notes,
    required this.isActive,
    required this.createdAt,
  });

  factory InventorySupplierDetail.fromMap(Map<String, dynamic> map) {
    return InventorySupplierDetail(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Proveedor',
      rnc: map['rnc']?.toString() ?? '',
      contactName: map['contact_name']?.toString() ?? '',
      phone: map['phone']?.toString() ?? '',
      email: map['email']?.toString() ?? '',
      address: map['address']?.toString() ?? '',
      paymentTerms: map['payment_terms']?.toString() ?? '',
      notes: map['notes']?.toString() ?? '',
      isActive: map['is_active'] != false,
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
    );
  }
}

/// PRD 9 Fase 1B — Versión completa de bodega para CRUD (incluye address,
/// is_active, created_at). La virtual `__IN_TRANSIT__` se identifica por
/// el `name` para que la UI la pueda mostrar como read-only.
class InventoryWarehouseDetail {
  final String id;
  final String name;
  final String address;
  final bool isMain;
  final bool isActive;
  final DateTime? createdAt;

  const InventoryWarehouseDetail({
    required this.id,
    required this.name,
    required this.address,
    required this.isMain,
    required this.isActive,
    required this.createdAt,
  });

  bool get isInTransit => name == '__IN_TRANSIT__';

  factory InventoryWarehouseDetail.fromMap(Map<String, dynamic> map) {
    return InventoryWarehouseDetail(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Almacen',
      address: map['address']?.toString() ?? '',
      isMain: map['is_main'] == true,
      isActive: map['is_active'] != false,
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
    );
  }
}

class InventoryItemSummary {
  final String id;
  final String sku;
  final String name;
  final String description;
  final String unit; // unidad BASE de stock (ej. ml)
  /// Conversión de empaque: unidad de COMPRA (ej. botella) y cuántas
  /// unidades base contiene (ej. 750). packSize=1 / purchaseUnit vacío =
  /// sin empaque (se compra en la unidad base).
  final String purchaseUnit;
  final double packSize;
  final double cost;
  final double minStock;
  final double? maxStock;
  final bool isActive;
  final double stock;
  // PRD 9 Fase 1D — campos extendidos.
  final String costingMethod; // 'average' | 'fifo'
  final String barcode;
  // Sprint 4 lotes — opt-in para tracking de lote / vencimiento.
  final bool tracksLots;
  // PRD inventario avanzado: clasificación.
  // Valores válidos: 'simple', 'raw_material', 'finished_product',
  // 'combo', 'service'. Default 'simple' = comportamiento legacy.
  final String itemClassification;

  const InventoryItemSummary({
    required this.id,
    required this.sku,
    required this.name,
    required this.description,
    required this.unit,
    this.purchaseUnit = '',
    this.packSize = 1,
    required this.cost,
    required this.minStock,
    required this.maxStock,
    required this.isActive,
    required this.stock,
    this.costingMethod = 'average',
    this.barcode = '',
    this.tracksLots = false,
    this.itemClassification = 'simple',
  });

  bool get isLowStock => isActive && stock <= minStock;

  factory InventoryItemSummary.fromMap(
    Map<String, dynamic> map, {
    required double stock,
  }) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    return InventoryItemSummary(
      id: map['id']?.toString() ?? '',
      sku: map['sku']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Insumo',
      description: map['description']?.toString() ?? '',
      unit: map['unit']?.toString() ?? 'unidad',
      purchaseUnit: map['purchase_unit']?.toString() ?? '',
      packSize: map['pack_size'] == null ? 1 : toDouble(map['pack_size']),
      cost: toDouble(map['cost']),
      minStock: toDouble(map['min_stock']),
      maxStock: map['max_stock'] == null ? null : toDouble(map['max_stock']),
      isActive: map['is_active'] != false,
      stock: stock,
      costingMethod: map['costing_method']?.toString() ?? 'average',
      barcode: map['barcode']?.toString() ?? '',
      tracksLots: map['tracks_lots'] == true,
      itemClassification:
          map['item_classification']?.toString() ?? 'simple',
    );
  }
}

class InventoryMovementEntry {
  final String id;
  final String itemId;
  final String itemName;
  final String warehouseId;
  final String warehouseName;
  final String movementType;
  final double quantity;
  final String notes;
  final String referenceType;
  final DateTime createdAt;

  const InventoryMovementEntry({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.warehouseId,
    required this.warehouseName,
    required this.movementType,
    required this.quantity,
    required this.notes,
    required this.referenceType,
    required this.createdAt,
  });

  bool get isOutflow => quantity < 0;

  factory InventoryMovementEntry.fromMap(
    Map<String, dynamic> map, {
    required String itemName,
    required String warehouseName,
  }) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    return InventoryMovementEntry(
      id: map['id']?.toString() ?? '',
      itemId: map['item_id']?.toString() ?? '',
      itemName: itemName,
      warehouseId: map['warehouse_id']?.toString() ?? '',
      warehouseName: warehouseName,
      movementType: map['movement_type']?.toString() ?? 'adjustment',
      quantity: toDouble(map['quantity']),
      notes: map['notes']?.toString() ?? '',
      referenceType: map['reference_type']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(map['created_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class InventoryState {
  final bool loading;
  final bool saving;
  final String? error;
  final String? businessId;
  final String? selectedWarehouseId;
  final String searchQuery;
  final List<InventoryWarehouse> warehouses;
  final List<InventoryItemSummary> items;
  final List<InventoryMovementEntry> movements;

  const InventoryState({
    this.loading = false,
    this.saving = false,
    this.error,
    this.businessId,
    this.selectedWarehouseId,
    this.searchQuery = '',
    this.warehouses = const [],
    this.items = const [],
    this.movements = const [],
  });

  InventoryState copyWith({
    bool? loading,
    bool? saving,
    String? error,
    String? businessId,
    String? selectedWarehouseId,
    String? searchQuery,
    List<InventoryWarehouse>? warehouses,
    List<InventoryItemSummary>? items,
    List<InventoryMovementEntry>? movements,
    bool clearError = false,
  }) {
    return InventoryState(
      loading: loading ?? this.loading,
      saving: saving ?? this.saving,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      selectedWarehouseId: selectedWarehouseId ?? this.selectedWarehouseId,
      searchQuery: searchQuery ?? this.searchQuery,
      warehouses: warehouses ?? this.warehouses,
      items: items ?? this.items,
      movements: movements ?? this.movements,
    );
  }
}
