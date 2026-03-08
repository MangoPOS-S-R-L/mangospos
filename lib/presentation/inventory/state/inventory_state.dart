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

class InventoryItemSummary {
  final String id;
  final String sku;
  final String name;
  final String description;
  final String unit;
  final double cost;
  final double minStock;
  final double? maxStock;
  final bool isActive;
  final double stock;

  const InventoryItemSummary({
    required this.id,
    required this.sku,
    required this.name,
    required this.description,
    required this.unit,
    required this.cost,
    required this.minStock,
    required this.maxStock,
    required this.isActive,
    required this.stock,
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
      cost: toDouble(map['cost']),
      minStock: toDouble(map['min_stock']),
      maxStock: map['max_stock'] == null ? null : toDouble(map['max_stock']),
      isActive: map['is_active'] != false,
      stock: stock,
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
