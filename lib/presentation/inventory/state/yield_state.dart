// Rendimiento por insumo: de lo que sale del almacén, cuánto va a producción /
// ventas y cuánto se pierde en merma. Datos de `fn_inventory_yield_analysis`
// (20260930_0050).

import 'outflow_reasons.dart';

double _num(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0;
}

int _int(dynamic v) {
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

/// Cantidad, valor y veces de una merma (por motivo).
class YieldWaste {
  const YieldWaste({this.qty = 0, this.value = 0, this.count = 0});

  final double qty;
  final double value;
  final int count;

  factory YieldWaste.fromMap(Map<String, dynamic> map) => YieldWaste(
    qty: _num(map['qty']),
    value: _num(map['value']),
    count: _int(map['count']),
  );
}

class YieldItem {
  const YieldItem({
    required this.itemId,
    required this.name,
    required this.sku,
    required this.unit,
    required this.unitCost,
    required this.currentStock,
    required this.purchasedQty,
    required this.purchasedValue,
    required this.consumedQty,
    required this.consumedValue,
    required this.producedQty,
    required this.wasteQty,
    required this.wasteValue,
    required this.countAdjustQty,
    required this.countAdjustValue,
    required this.wasteByReason,
  });

  final String itemId;
  final String name;
  final String sku;
  final String unit;
  final double unitCost;
  final double currentStock;

  /// Compra NETA del período (con las reversas de editar/anular compras).
  final double purchasedQty;
  final double purchasedValue;

  /// Lo que se fue a producción y ventas (neto de devoluciones).
  final double consumedQty;
  final double consumedValue;

  /// Producto terminado que entró por producción.
  final double producedQty;

  /// Merma total (todas las razones).
  final double wasteQty;
  final double wasteValue;

  /// Diferencias de conteo físico / correcciones: ni producción ni merma
  /// declarada. Negativo = faltó.
  final double countAdjustQty;
  final double countAdjustValue;

  final Map<String, YieldWaste> wasteByReason;

  /// Merma de UN motivo (o toda si [reason] es null).
  YieldWaste wasteFor(String? reason) => reason == null
      ? YieldWaste(qty: wasteQty, value: wasteValue)
      : (wasteByReason[reason] ?? const YieldWaste());

  /// De lo que SALIÓ (producción + merma), qué fracción fue merma. `null`
  /// cuando no salió nada.
  double? wasteShare({String? reason}) {
    final out = consumedQty + wasteQty;
    if (out <= 0) return null;
    return (wasteFor(reason).qty / out).clamp(0, 1).toDouble();
  }

  /// Rendimiento: fracción de lo que salió que fue producción / ventas.
  double? get yieldShare {
    final share = wasteShare();
    return share == null ? null : 1 - share;
  }

  factory YieldItem.fromMap(Map<String, dynamic> map) {
    final raw = map['waste_by_reason'];
    final byReason = <String, YieldWaste>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is Map) {
          byReason[k.toString()] = YieldWaste.fromMap(
            Map<String, dynamic>.from(v),
          );
        }
      });
    }
    return YieldItem(
      itemId: map['item_id']?.toString() ?? '',
      name: map['item_name']?.toString() ?? 'Insumo',
      sku: map['item_sku']?.toString() ?? '',
      unit: map['item_unit']?.toString() ?? '',
      unitCost: _num(map['unit_cost']),
      currentStock: _num(map['current_stock']),
      purchasedQty: _num(map['purchased_qty']),
      purchasedValue: _num(map['purchased_value']),
      consumedQty: _num(map['consumed_qty']),
      consumedValue: _num(map['consumed_value']),
      producedQty: _num(map['produced_qty']),
      wasteQty: _num(map['waste_qty']),
      wasteValue: _num(map['waste_value']),
      countAdjustQty: _num(map['count_adjust_qty']),
      countAdjustValue: _num(map['count_adjust_value']),
      wasteByReason: byReason,
    );
  }
}

class YieldReasonTotal {
  const YieldReasonTotal({
    required this.reason,
    required this.qty,
    required this.value,
    required this.count,
  });

  final String reason;
  final double qty;
  final double value;
  final int count;

  OutflowReason get info => outflowReasonByCode(reason);

  factory YieldReasonTotal.fromMap(Map<String, dynamic> map) =>
      YieldReasonTotal(
        reason: map['reason']?.toString() ?? kUnspecifiedReason,
        qty: _num(map['qty']),
        value: _num(map['value']),
        count: _int(map['count']),
      );
}

class YieldDay {
  const YieldDay({
    required this.day,
    required this.consumedValue,
    required this.wasteValue,
  });

  /// Día de RD (fecha sin hora).
  final DateTime day;
  final double consumedValue;
  final double wasteValue;

  factory YieldDay.fromMap(Map<String, dynamic> map) => YieldDay(
    day: DateTime.tryParse(map['day']?.toString() ?? '') ?? DateTime(2000),
    consumedValue: _num(map['consumed_value']),
    wasteValue: _num(map['waste_value']),
  );
}

class YieldReport {
  const YieldReport({
    required this.days,
    required this.items,
    required this.byReason,
    required this.daily,
    this.from,
    this.to,
  });

  final int days;
  final DateTime? from;
  final DateTime? to;
  final List<YieldItem> items;
  final List<YieldReasonTotal> byReason;
  final List<YieldDay> daily;

  static const empty = YieldReport(days: 0, items: [], byReason: [], daily: []);

  double get purchasedValue =>
      items.fold(0, (sum, i) => sum + i.purchasedValue);
  double get consumedValue => items.fold(0, (sum, i) => sum + i.consumedValue);
  double get wasteValue => items.fold(0, (sum, i) => sum + i.wasteValue);
  double get countAdjustValue =>
      items.fold(0, (sum, i) => sum + i.countAdjustValue);

  /// De lo que salió EN DINERO, qué fracción fue merma.
  double? get wasteShare {
    final out = consumedValue + wasteValue;
    if (out <= 0) return null;
    return (wasteValue / out).clamp(0, 1).toDouble();
  }

  bool get isEmpty => items.isEmpty;

  factory YieldReport.fromMap(Map<String, dynamic> map) {
    List<Map<String, dynamic>> list(dynamic raw) => raw is List
        ? raw.whereType<Map>().map(Map<String, dynamic>.from).toList()
        : const [];
    return YieldReport(
      days: _int(map['days']),
      from: DateTime.tryParse(map['from']?.toString() ?? ''),
      to: DateTime.tryParse(map['to']?.toString() ?? ''),
      items: list(map['items']).map(YieldItem.fromMap).toList(growable: false),
      byReason: list(
        map['by_reason'],
      ).map(YieldReasonTotal.fromMap).toList(growable: false),
      daily: list(map['daily']).map(YieldDay.fromMap).toList(growable: false),
    );
  }
}

/// Orden de la tabla de insumos.
enum YieldSort { wasteValue, wasteShare, consumedValue, name }

const yieldPeriods = <int>[7, 30, 60, 90];

class YieldWarehouseOption {
  const YieldWarehouseOption(this.id, this.name);
  final String id;
  final String name;
}

class YieldState {
  const YieldState({
    this.loading = false,
    this.error,
    this.missingFunction = false,
    this.businessId,
    this.daysBack = 30,
    this.warehouseId,
    this.warehouses = const [],
    this.report = YieldReport.empty,
    this.reasonFilter,
    this.search = '',
    this.sort = YieldSort.wasteValue,
  });

  final bool loading;
  final String? error;

  /// El servidor no tiene la función (migración 20260930_0050 sin aplicar).
  final bool missingFunction;
  final String? businessId;
  final int daysBack;

  /// `null` = todas las bodegas.
  final String? warehouseId;
  final List<YieldWarehouseOption> warehouses;
  final YieldReport report;

  /// Motivo elegido (`null` = todos).
  final String? reasonFilter;
  final String search;
  final YieldSort sort;

  /// Insumos de la tabla: filtrados por motivo y búsqueda, y ordenados.
  List<YieldItem> get visibleItems {
    final q = search.trim().toLowerCase();
    final reason = reasonFilter;
    final rows = report.items.where((i) {
      if (reason != null && (i.wasteByReason[reason]?.qty ?? 0) <= 0) {
        return false;
      }
      if (q.isEmpty) return true;
      return i.name.toLowerCase().contains(q) ||
          i.sku.toLowerCase().contains(q);
    }).toList();
    int byDesc(double a, double b) => b.compareTo(a);
    switch (sort) {
      case YieldSort.wasteValue:
        rows.sort(
          (a, b) => byDesc(a.wasteFor(reason).value, b.wasteFor(reason).value),
        );
      case YieldSort.wasteShare:
        rows.sort(
          (a, b) => byDesc(
            a.wasteShare(reason: reason) ?? -1,
            b.wasteShare(reason: reason) ?? -1,
          ),
        );
      case YieldSort.consumedValue:
        rows.sort((a, b) => byDesc(a.consumedValue, b.consumedValue));
      case YieldSort.name:
        rows.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    }
    return rows;
  }

  YieldState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    bool? missingFunction,
    String? businessId,
    int? daysBack,
    String? warehouseId,
    bool clearWarehouse = false,
    List<YieldWarehouseOption>? warehouses,
    YieldReport? report,
    String? reasonFilter,
    bool clearReason = false,
    String? search,
    YieldSort? sort,
  }) {
    return YieldState(
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      missingFunction: missingFunction ?? this.missingFunction,
      businessId: businessId ?? this.businessId,
      daysBack: daysBack ?? this.daysBack,
      warehouseId: clearWarehouse ? null : (warehouseId ?? this.warehouseId),
      warehouses: warehouses ?? this.warehouses,
      report: report ?? this.report,
      reasonFilter: clearReason ? null : (reasonFilter ?? this.reasonFilter),
      search: search ?? this.search,
      sort: sort ?? this.sort,
    );
  }
}
