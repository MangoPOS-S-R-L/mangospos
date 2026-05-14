// Sprint 3 Inventario — Estado del Kardex (historial de movimientos con
// saldo corrido). Modelo, filtros y estado del viewmodel.

class KardexMovement {
  final String id;
  final String businessId;
  final String warehouseId;
  final String warehouseName;
  final String itemId;
  final String itemName;
  final String itemSku;
  final String itemUnit;
  final String movementType;
  final double quantity; // signed
  final double quantityAbs;
  final double? costPerUnit;
  final double totalValue;
  final String? reasonCode;
  final String? referenceId;
  final String? referenceType;
  final String? notes;
  final String? createdBy;
  final String? createdByName;
  final DateTime? createdAt;
  final double runningBalance;

  const KardexMovement({
    required this.id,
    required this.businessId,
    required this.warehouseId,
    required this.warehouseName,
    required this.itemId,
    required this.itemName,
    required this.itemSku,
    required this.itemUnit,
    required this.movementType,
    required this.quantity,
    required this.quantityAbs,
    required this.totalValue,
    required this.runningBalance,
    this.costPerUnit,
    this.reasonCode,
    this.referenceId,
    this.referenceType,
    this.notes,
    this.createdBy,
    this.createdByName,
    this.createdAt,
  });

  /// True si el movimiento incrementa stock (cantidad > 0).
  bool get isInbound => quantity > 0;

  factory KardexMovement.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
    }

    double? toNullableDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    return KardexMovement(
      id: map['id']?.toString() ?? '',
      businessId: map['business_id']?.toString() ?? '',
      warehouseId: map['warehouse_id']?.toString() ?? '',
      warehouseName: map['warehouse_name']?.toString() ?? '—',
      itemId: map['item_id']?.toString() ?? '',
      itemName: map['item_name']?.toString() ?? '—',
      itemSku: map['item_sku']?.toString() ?? '',
      itemUnit: map['item_unit']?.toString() ?? 'unidad',
      movementType: map['movement_type']?.toString() ?? 'adjustment',
      quantity: toDouble(map['quantity']),
      quantityAbs: toDouble(map['quantity_abs']),
      costPerUnit: toNullableDouble(map['cost_per_unit']),
      totalValue: toDouble(map['total_value']),
      reasonCode: map['reason_code']?.toString(),
      referenceId: map['reference_id']?.toString(),
      referenceType: map['reference_type']?.toString(),
      notes: map['notes']?.toString(),
      createdBy: map['created_by']?.toString(),
      createdByName: map['created_by_name']?.toString(),
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
      runningBalance: toDouble(map['running_balance']),
    );
  }
}

/// Filtros aplicados al Kardex. Inmutables: cualquier cambio crea una nueva
/// instancia que dispara recarga desde el inicio (offset 0).
class KardexFilters {
  final String? itemId;
  final String? warehouseId;
  final String? movementType;
  final String? createdBy;
  final DateTime? from;
  final DateTime? to;

  const KardexFilters({
    this.itemId,
    this.warehouseId,
    this.movementType,
    this.createdBy,
    this.from,
    this.to,
  });

  bool get isEmpty =>
      itemId == null &&
      warehouseId == null &&
      movementType == null &&
      createdBy == null &&
      from == null &&
      to == null;

  KardexFilters copyWith({
    String? itemId,
    String? warehouseId,
    String? movementType,
    String? createdBy,
    DateTime? from,
    DateTime? to,
    bool clearItemId = false,
    bool clearWarehouseId = false,
    bool clearMovementType = false,
    bool clearCreatedBy = false,
    bool clearFrom = false,
    bool clearTo = false,
  }) {
    return KardexFilters(
      itemId: clearItemId ? null : (itemId ?? this.itemId),
      warehouseId: clearWarehouseId ? null : (warehouseId ?? this.warehouseId),
      movementType: clearMovementType
          ? null
          : (movementType ?? this.movementType),
      createdBy: clearCreatedBy ? null : (createdBy ?? this.createdBy),
      from: clearFrom ? null : (from ?? this.from),
      to: clearTo ? null : (to ?? this.to),
    );
  }
}

class KardexState {
  /// Tamaño de página para la paginación del Kardex.
  static const pageSize = 100;

  final bool loading;
  final bool loadingMore;
  final String? error;
  final String? businessId;
  final KardexFilters filters;
  final List<KardexMovement> movements;
  final bool hasMore;

  const KardexState({
    this.loading = false,
    this.loadingMore = false,
    this.error,
    this.businessId,
    this.filters = const KardexFilters(),
    this.movements = const [],
    this.hasMore = false,
  });

  KardexState copyWith({
    bool? loading,
    bool? loadingMore,
    String? error,
    String? businessId,
    KardexFilters? filters,
    List<KardexMovement>? movements,
    bool? hasMore,
    bool clearError = false,
  }) {
    return KardexState(
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      filters: filters ?? this.filters,
      movements: movements ?? this.movements,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}
