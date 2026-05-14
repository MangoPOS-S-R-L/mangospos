// Sprint 4 Inventario — Estado de lotes y vencimientos (fase 1).

enum LotStatus { active, depleted, disposed, unknown }

LotStatus _parseStatus(String? raw) {
  switch (raw) {
    case 'active':
      return LotStatus.active;
    case 'depleted':
      return LotStatus.depleted;
    case 'disposed':
      return LotStatus.disposed;
    default:
      return LotStatus.unknown;
  }
}

/// Estado calculado por la vista combinando status crudo + vencimiento.
enum LotExpiryStatus {
  fresh,
  warning, // ≤30 días
  critical, // ≤7 días
  expired,
  depleted,
  disposed,
  unknown,
}

LotExpiryStatus _parseExpiryStatus(String? raw) {
  switch (raw) {
    case 'fresh':
      return LotExpiryStatus.fresh;
    case 'warning':
      return LotExpiryStatus.warning;
    case 'critical':
      return LotExpiryStatus.critical;
    case 'expired':
      return LotExpiryStatus.expired;
    case 'depleted':
      return LotExpiryStatus.depleted;
    case 'disposed':
      return LotExpiryStatus.disposed;
    default:
      return LotExpiryStatus.unknown;
  }
}

class InventoryLot {
  final String id;
  final String businessId;
  final String itemId;
  final String itemName;
  final String itemSku;
  final String itemUnit;
  final String warehouseId;
  final String warehouseName;
  final String lotNumber;
  final DateTime? expiryDate;
  final DateTime? receivedDate;
  final double receivedQuantity;
  final double remainingQuantity;
  final double? costPerUnit;
  final double remainingValue;
  final String sourceType;
  final String? sourceId;
  final LotStatus status;
  final LotExpiryStatus expiryStatus;
  final int? daysUntilExpiry;
  final String? notes;
  final String? disposedReason;
  final DateTime? disposedAt;
  final String? disposedByName;
  final String? createdByName;
  final DateTime? createdAt;

  const InventoryLot({
    required this.id,
    required this.businessId,
    required this.itemId,
    required this.itemName,
    required this.itemSku,
    required this.itemUnit,
    required this.warehouseId,
    required this.warehouseName,
    required this.lotNumber,
    required this.expiryDate,
    required this.receivedDate,
    required this.receivedQuantity,
    required this.remainingQuantity,
    required this.costPerUnit,
    required this.remainingValue,
    required this.sourceType,
    required this.sourceId,
    required this.status,
    required this.expiryStatus,
    required this.daysUntilExpiry,
    required this.notes,
    required this.disposedReason,
    required this.disposedAt,
    required this.disposedByName,
    required this.createdByName,
    required this.createdAt,
  });

  bool get isActive => status == LotStatus.active;
  bool get isExpired => expiryStatus == LotExpiryStatus.expired;

  factory InventoryLot.fromMap(Map<String, dynamic> map) {
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

    int? toNullableInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    return InventoryLot(
      id: map['id']?.toString() ?? '',
      businessId: map['business_id']?.toString() ?? '',
      itemId: map['item_id']?.toString() ?? '',
      itemName: map['item_name']?.toString() ?? '—',
      itemSku: map['item_sku']?.toString() ?? '',
      itemUnit: map['item_unit']?.toString() ?? 'unidad',
      warehouseId: map['warehouse_id']?.toString() ?? '',
      warehouseName: map['warehouse_name']?.toString() ?? 'Almacén',
      lotNumber: map['lot_number']?.toString() ?? '',
      expiryDate: DateTime.tryParse(map['expiry_date']?.toString() ?? ''),
      receivedDate: DateTime.tryParse(map['received_date']?.toString() ?? ''),
      receivedQuantity: toDouble(map['received_quantity']),
      remainingQuantity: toDouble(map['remaining_quantity']),
      costPerUnit: toNullableDouble(map['cost_per_unit']),
      remainingValue: toDouble(map['remaining_value']),
      sourceType: map['source_type']?.toString() ?? 'manual',
      sourceId: map['source_id']?.toString(),
      status: _parseStatus(map['status']?.toString()),
      expiryStatus: _parseExpiryStatus(map['expiry_status']?.toString()),
      daysUntilExpiry: toNullableInt(map['days_until_expiry']),
      notes: map['notes']?.toString(),
      disposedReason: map['disposed_reason']?.toString(),
      disposedAt: DateTime.tryParse(map['disposed_at']?.toString() ?? ''),
      disposedByName: map['disposed_by_name']?.toString(),
      createdByName: map['created_by_name']?.toString(),
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
    );
  }
}

class LotsFilters {
  /// Filtra por estado calculado (fresh/warning/critical/expired/...).
  final String? expiryStatus;
  final String? itemId;
  final String? warehouseId;

  const LotsFilters({this.expiryStatus, this.itemId, this.warehouseId});

  bool get isEmpty =>
      expiryStatus == null && itemId == null && warehouseId == null;

  LotsFilters copyWith({
    String? expiryStatus,
    String? itemId,
    String? warehouseId,
    bool clearExpiryStatus = false,
    bool clearItemId = false,
    bool clearWarehouseId = false,
  }) {
    return LotsFilters(
      expiryStatus: clearExpiryStatus
          ? null
          : (expiryStatus ?? this.expiryStatus),
      itemId: clearItemId ? null : (itemId ?? this.itemId),
      warehouseId: clearWarehouseId ? null : (warehouseId ?? this.warehouseId),
    );
  }
}

class LotsState {
  static const pageSize = 100;

  final bool loading;
  final bool loadingMore;
  final bool saving;
  final String? error;
  final String? businessId;
  final LotsFilters filters;
  final List<InventoryLot> lots;
  final bool hasMore;

  const LotsState({
    this.loading = false,
    this.loadingMore = false,
    this.saving = false,
    this.error,
    this.businessId,
    this.filters = const LotsFilters(),
    this.lots = const [],
    this.hasMore = false,
  });

  int countByExpiry(LotExpiryStatus status) =>
      lots.where((l) => l.expiryStatus == status).length;

  LotsState copyWith({
    bool? loading,
    bool? loadingMore,
    bool? saving,
    String? error,
    String? businessId,
    LotsFilters? filters,
    List<InventoryLot>? lots,
    bool? hasMore,
    bool clearError = false,
  }) {
    return LotsState(
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      saving: saving ?? this.saving,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      filters: filters ?? this.filters,
      lots: lots ?? this.lots,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}
