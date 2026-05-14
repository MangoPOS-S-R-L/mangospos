// Sprint 5 Inventario (Fase A) — Estado de valoración de existencias + ABC.

enum AbcClass { a, b, c, noData, unknown }

AbcClass _parseAbc(String? raw) {
  switch (raw) {
    case 'A':
      return AbcClass.a;
    case 'B':
      return AbcClass.b;
    case 'C':
      return AbcClass.c;
    case 'no_data':
      return AbcClass.noData;
    default:
      return AbcClass.unknown;
  }
}

/// Detalle por (item × bodega). Una fila por combinación.
class ValuationRow {
  final String businessId;
  final String itemId;
  final String itemSku;
  final String itemName;
  final String itemUnit;
  final double unitCost;
  final double minStock;
  final double? maxStock;
  final bool tracksLots;
  final String warehouseId;
  final String warehouseName;
  final bool warehouseIsMain;
  final double quantity;
  final double value;
  final DateTime? lastMovementAt;

  const ValuationRow({
    required this.businessId,
    required this.itemId,
    required this.itemSku,
    required this.itemName,
    required this.itemUnit,
    required this.unitCost,
    required this.minStock,
    required this.maxStock,
    required this.tracksLots,
    required this.warehouseId,
    required this.warehouseName,
    required this.warehouseIsMain,
    required this.quantity,
    required this.value,
    required this.lastMovementAt,
  });

  factory ValuationRow.fromMap(Map<String, dynamic> map) {
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

    return ValuationRow(
      businessId: map['business_id']?.toString() ?? '',
      itemId: map['item_id']?.toString() ?? '',
      itemSku: map['item_sku']?.toString() ?? '',
      itemName: map['item_name']?.toString() ?? '—',
      itemUnit: map['item_unit']?.toString() ?? 'unidad',
      unitCost: toDouble(map['unit_cost']),
      minStock: toDouble(map['min_stock']),
      maxStock: toNullableDouble(map['max_stock']),
      tracksLots: map['tracks_lots'] == true,
      warehouseId: map['warehouse_id']?.toString() ?? '',
      warehouseName: map['warehouse_name']?.toString() ?? '—',
      warehouseIsMain: map['warehouse_is_main'] == true,
      quantity: toDouble(map['quantity']),
      value: toDouble(map['value']),
      lastMovementAt: DateTime.tryParse(
        map['last_movement_at']?.toString() ?? '',
      ),
    );
  }
}

/// Resumen agregado por insumo con clase ABC.
class ValuationSummaryRow {
  final String businessId;
  final String itemId;
  final String itemSku;
  final String itemName;
  final String itemUnit;
  final double unitCost;
  final double minStock;
  final double? maxStock;
  final bool tracksLots;
  final double totalQuantity;
  final double totalValue;
  final int warehousesWithStock;
  final DateTime? lastMovementAt;
  final double businessTotalValue;
  final double? cumulativePct;
  final AbcClass abcClass;

  const ValuationSummaryRow({
    required this.businessId,
    required this.itemId,
    required this.itemSku,
    required this.itemName,
    required this.itemUnit,
    required this.unitCost,
    required this.minStock,
    required this.maxStock,
    required this.tracksLots,
    required this.totalQuantity,
    required this.totalValue,
    required this.warehousesWithStock,
    required this.lastMovementAt,
    required this.businessTotalValue,
    required this.cumulativePct,
    required this.abcClass,
  });

  /// Porcentaje del total que representa este item.
  double get valuePct =>
      businessTotalValue > 0 ? totalValue / businessTotalValue : 0;

  factory ValuationSummaryRow.fromMap(Map<String, dynamic> map) {
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

    int toInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString()) ?? 0;
    }

    return ValuationSummaryRow(
      businessId: map['business_id']?.toString() ?? '',
      itemId: map['item_id']?.toString() ?? '',
      itemSku: map['item_sku']?.toString() ?? '',
      itemName: map['item_name']?.toString() ?? '—',
      itemUnit: map['item_unit']?.toString() ?? 'unidad',
      unitCost: toDouble(map['unit_cost']),
      minStock: toDouble(map['min_stock']),
      maxStock: toNullableDouble(map['max_stock']),
      tracksLots: map['tracks_lots'] == true,
      totalQuantity: toDouble(map['total_quantity']),
      totalValue: toDouble(map['total_value']),
      warehousesWithStock: toInt(map['warehouses_with_stock']),
      lastMovementAt: DateTime.tryParse(
        map['last_movement_at']?.toString() ?? '',
      ),
      businessTotalValue: toDouble(map['business_total_value']),
      cumulativePct: toNullableDouble(map['cumulative_pct']),
      abcClass: _parseAbc(map['abc_class']?.toString()),
    );
  }
}

/// Filtros de la vista de valoración.
class ValuationFilters {
  /// 'A' | 'B' | 'C' | 'no_data' o null para todas.
  final String? abcClass;
  final String? warehouseId;

  const ValuationFilters({this.abcClass, this.warehouseId});

  bool get isEmpty => abcClass == null && warehouseId == null;

  ValuationFilters copyWith({
    String? abcClass,
    String? warehouseId,
    bool clearAbc = false,
    bool clearWarehouse = false,
  }) {
    return ValuationFilters(
      abcClass: clearAbc ? null : (abcClass ?? this.abcClass),
      warehouseId: clearWarehouse
          ? null
          : (warehouseId ?? this.warehouseId),
    );
  }
}

enum ValuationViewMode { byItem, byWarehouse }

class ValuationState {
  final bool loading;
  final String? error;
  final String? businessId;
  final ValuationViewMode viewMode;
  final ValuationFilters filters;
  /// Lista agregada por insumo (usado en modo "por item").
  final List<ValuationSummaryRow> summary;
  /// Detalle por (item × bodega) (usado en modo "por bodega" o drilldown).
  final List<ValuationRow> details;

  const ValuationState({
    this.loading = false,
    this.error,
    this.businessId,
    this.viewMode = ValuationViewMode.byItem,
    this.filters = const ValuationFilters(),
    this.summary = const [],
    this.details = const [],
  });

  /// Total valorizado del business (suma de todos los items).
  double get totalValue {
    if (summary.isEmpty) {
      // Fallback: suma desde detalles si solo tenemos esa.
      return details.fold(0.0, (sum, r) => sum + r.value);
    }
    // Todos los rows comparten el mismo business_total_value.
    return summary.first.businessTotalValue;
  }

  /// Suma del valor filtrado (puede ser parcial si filtras por ABC).
  double get filteredValue =>
      summary.fold(0.0, (sum, r) => sum + r.totalValue);

  int countAbc(AbcClass cls) =>
      summary.where((r) => r.abcClass == cls).length;

  ValuationState copyWith({
    bool? loading,
    String? error,
    String? businessId,
    ValuationViewMode? viewMode,
    ValuationFilters? filters,
    List<ValuationSummaryRow>? summary,
    List<ValuationRow>? details,
    bool clearError = false,
  }) {
    return ValuationState(
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      viewMode: viewMode ?? this.viewMode,
      filters: filters ?? this.filters,
      summary: summary ?? this.summary,
      details: details ?? this.details,
    );
  }
}
