// Sprint 4 Inventario — Estado de alertas de stock bajo.

enum LowStockAlertLevel { outOfStock, critical, low, unknown }

LowStockAlertLevel _parseAlertLevel(String? raw) {
  switch (raw) {
    case 'out_of_stock':
      return LowStockAlertLevel.outOfStock;
    case 'critical':
      return LowStockAlertLevel.critical;
    case 'low':
      return LowStockAlertLevel.low;
    default:
      return LowStockAlertLevel.unknown;
  }
}

class LowStockAlert {
  final String itemId;
  final String businessId;
  final String sku;
  final String name;
  final String unit;
  final double cost;
  final double minStock;
  final double? maxStock;
  final double totalStock;
  final int warehousesWithStock;
  final DateTime? lastMovementAt;
  final LowStockAlertLevel alertLevel;
  final double shortfall;
  final double shortfallValue;

  const LowStockAlert({
    required this.itemId,
    required this.businessId,
    required this.sku,
    required this.name,
    required this.unit,
    required this.cost,
    required this.minStock,
    required this.maxStock,
    required this.totalStock,
    required this.warehousesWithStock,
    required this.lastMovementAt,
    required this.alertLevel,
    required this.shortfall,
    required this.shortfallValue,
  });

  factory LowStockAlert.fromMap(Map<String, dynamic> map) {
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

    return LowStockAlert(
      itemId: map['item_id']?.toString() ?? '',
      businessId: map['business_id']?.toString() ?? '',
      sku: map['sku']?.toString() ?? '',
      name: map['name']?.toString() ?? '—',
      unit: map['unit']?.toString() ?? 'unidad',
      cost: toDouble(map['cost']),
      minStock: toDouble(map['min_stock']),
      maxStock: toNullableDouble(map['max_stock']),
      totalStock: toDouble(map['total_stock']),
      warehousesWithStock: toInt(map['warehouses_with_stock']),
      lastMovementAt: DateTime.tryParse(
        map['last_movement_at']?.toString() ?? '',
      ),
      alertLevel: _parseAlertLevel(map['alert_level']?.toString()),
      shortfall: toDouble(map['shortfall']),
      shortfallValue: toDouble(map['shortfall_value']),
    );
  }
}

/// Stock por bodega para un insumo específico (drilldown del alerta).
class StockByWarehouse {
  final String itemId;
  final String itemName;
  final String warehouseId;
  final String warehouseName;
  final bool warehouseIsMain;
  final double quantity;
  final double minStock;
  final String unit;
  final DateTime? lastUpdated;

  const StockByWarehouse({
    required this.itemId,
    required this.itemName,
    required this.warehouseId,
    required this.warehouseName,
    required this.warehouseIsMain,
    required this.quantity,
    required this.minStock,
    required this.unit,
    required this.lastUpdated,
  });

  factory StockByWarehouse.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
    }

    return StockByWarehouse(
      itemId: map['item_id']?.toString() ?? '',
      itemName: map['item_name']?.toString() ?? '—',
      warehouseId: map['warehouse_id']?.toString() ?? '',
      warehouseName: map['warehouse_name']?.toString() ?? '—',
      warehouseIsMain: map['warehouse_is_main'] == true,
      quantity: toDouble(map['quantity']),
      minStock: toDouble(map['min_stock']),
      unit: map['item_unit']?.toString() ?? 'unidad',
      lastUpdated: DateTime.tryParse(map['last_updated']?.toString() ?? ''),
    );
  }
}

class LowStockState {
  final bool loading;
  final String? error;
  final String? businessId;
  /// Filtro opcional por nivel ('out_of_stock' | 'critical' | 'low').
  final String? alertLevelFilter;
  final List<LowStockAlert> alerts;

  const LowStockState({
    this.loading = false,
    this.error,
    this.businessId,
    this.alertLevelFilter,
    this.alerts = const [],
  });

  /// Cuántas alertas de cada nivel hay en la lista actual.
  int countOf(LowStockAlertLevel level) =>
      alerts.where((a) => a.alertLevel == level).length;

  /// Valor total estimado del shortfall (cuánto cuesta reponer al mínimo).
  double get totalShortfallValue =>
      alerts.fold(0.0, (sum, a) => sum + a.shortfallValue);

  LowStockState copyWith({
    bool? loading,
    String? error,
    String? businessId,
    String? alertLevelFilter,
    List<LowStockAlert>? alerts,
    bool clearError = false,
    bool clearFilter = false,
  }) {
    return LowStockState(
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      alertLevelFilter: clearFilter
          ? null
          : (alertLevelFilter ?? this.alertLevelFilter),
      alerts: alerts ?? this.alerts,
    );
  }
}
