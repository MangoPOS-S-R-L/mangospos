// Sprint 5 Inventario (Fase B) — Estado de análisis de rotación.

enum RotationClass { star, active, slow, dormant, unknown }

RotationClass _parseRotation(String? raw) {
  switch (raw) {
    case 'star':
      return RotationClass.star;
    case 'active':
      return RotationClass.active;
    case 'slow':
      return RotationClass.slow;
    case 'dormant':
      return RotationClass.dormant;
    default:
      return RotationClass.unknown;
  }
}

class RotationRow {
  final String itemId;
  final String itemSku;
  final String itemName;
  final String itemUnit;
  final double unitCost;
  final double minStock;
  final bool tracksLots;
  final double currentStock;
  final double outflowQty;
  final double inflowQty;
  final double outflowValue;
  final int movementCount;
  final double outflowPerDay;
  final double? daysOfSupply;
  final RotationClass rotationClass;

  const RotationRow({
    required this.itemId,
    required this.itemSku,
    required this.itemName,
    required this.itemUnit,
    required this.unitCost,
    required this.minStock,
    required this.tracksLots,
    required this.currentStock,
    required this.outflowQty,
    required this.inflowQty,
    required this.outflowValue,
    required this.movementCount,
    required this.outflowPerDay,
    required this.daysOfSupply,
    required this.rotationClass,
  });

  /// `true` cuando los días de supply son menores al período medido, lo que
  /// sugiere riesgo de quiebre si la velocidad se mantiene.
  bool needsReplenishAlert(int periodDays) {
    final dos = daysOfSupply;
    if (dos == null) return false;
    return dos < periodDays;
  }

  factory RotationRow.fromMap(Map<String, dynamic> map) {
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

    return RotationRow(
      itemId: map['item_id']?.toString() ?? '',
      itemSku: map['item_sku']?.toString() ?? '',
      itemName: map['item_name']?.toString() ?? '—',
      itemUnit: map['item_unit']?.toString() ?? 'unidad',
      unitCost: toDouble(map['unit_cost']),
      minStock: toDouble(map['min_stock']),
      tracksLots: map['tracks_lots'] == true,
      currentStock: toDouble(map['current_stock']),
      outflowQty: toDouble(map['outflow_qty']),
      inflowQty: toDouble(map['inflow_qty']),
      outflowValue: toDouble(map['outflow_value']),
      movementCount: toInt(map['movement_count']),
      outflowPerDay: toDouble(map['outflow_per_day']),
      daysOfSupply: toNullableDouble(map['days_of_supply']),
      rotationClass: _parseRotation(map['rotation_class']?.toString()),
    );
  }
}

/// Ventanas predefinidas para el análisis.
const rotationPresets = <int>[7, 30, 60, 90];

class RotationState {
  final bool loading;
  final String? error;
  final String? businessId;
  final int daysBack;
  final RotationClass? classFilter;
  final List<RotationRow> rows;

  const RotationState({
    this.loading = false,
    this.error,
    this.businessId,
    this.daysBack = 30,
    this.classFilter,
    this.rows = const [],
  });

  int countClass(RotationClass cls) =>
      rows.where((r) => r.rotationClass == cls).length;

  /// Total de unidades movidas en el período (output).
  double get totalOutflow =>
      rows.fold(0.0, (sum, r) => sum + r.outflowQty);

  /// Valor del outflow (lo que "salió") en el período.
  double get totalOutflowValue =>
      rows.fold(0.0, (sum, r) => sum + r.outflowValue);

  RotationState copyWith({
    bool? loading,
    String? error,
    String? businessId,
    int? daysBack,
    RotationClass? classFilter,
    List<RotationRow>? rows,
    bool clearError = false,
    bool clearClassFilter = false,
  }) {
    return RotationState(
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      daysBack: daysBack ?? this.daysBack,
      classFilter: clearClassFilter
          ? null
          : (classFilter ?? this.classFilter),
      rows: rows ?? this.rows,
    );
  }
}
