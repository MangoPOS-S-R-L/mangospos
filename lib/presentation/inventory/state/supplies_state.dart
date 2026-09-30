// Gastables y menaje: lo que el negocio compra y NO vende. Datos de
// `fn_inventory_supplies_overview` (20260930_0051).
//
// Dos preguntas distintas, una por pestaña:
//   · Gastables (papel, cloro, servilletas): ¿cuánto se USA, dónde, y cuándo
//     se acaba?
//   · Menaje (copas, platos, ollas): ¿cuántas HAY contra cuántas debe haber
//     (el par), y cuántas se rompen o se pierden?

import '../../../core/inventory/item_classification.dart';

double _num(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0;
}

int _int(dynamic v) {
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

/// Períodos que ofrece la pantalla, en días.
const suppliesPeriods = [7, 30, 90];

enum SuppliesTab { supplies, smallware }

/// Existencia de un artículo en UNA bodega.
class SupplyWarehouseStock {
  const SupplyWarehouseStock({
    required this.warehouseId,
    required this.warehouseName,
    required this.qty,
    this.minStock,
  });

  final String warehouseId;
  final String warehouseName;
  final double qty;

  /// Mínimo (par) de ESA bodega; `null` si no tiene uno propio.
  final double? minStock;

  factory SupplyWarehouseStock.fromMap(Map<String, dynamic> map) =>
      SupplyWarehouseStock(
        warehouseId: map['warehouse_id']?.toString() ?? '',
        warehouseName: map['warehouse_name']?.toString() ?? 'Bodega',
        qty: _num(map['qty']),
        minStock: map['min_stock'] == null ? null : _num(map['min_stock']),
      );
}

class SupplyItem {
  const SupplyItem({
    required this.itemId,
    required this.name,
    this.sku = '',
    this.unit = '',
    required this.classification,
    this.unitCost = 0,
    this.stock = 0,
    this.minStock = 0,
    this.minFromWarehouse = false,
    this.purchasedQty = 0,
    this.purchasedValue = 0,
    this.soldQty = 0,
    this.soldValue = 0,
    this.usedQty = 0,
    this.usedValue = 0,
    this.brokenQty = 0,
    this.brokenValue = 0,
    this.lostQty = 0,
    this.lostValue = 0,
    this.otherOutQty = 0,
    this.otherOutValue = 0,
    this.countAdjustQty = 0,
    this.countAdjustValue = 0,
    this.byWarehouse = const [],
  });

  final String itemId;
  final String name;
  final String sku;
  final String unit;
  final String classification;
  final double unitCost;
  final double stock;

  /// Mínimo; en el menaje es el PAR (cuántas debe haber).
  final double minStock;

  /// El mínimo es el de la bodega elegida, no el general del insumo.
  final bool minFromWarehouse;

  final double purchasedQty;
  final double purchasedValue;

  /// Salió por venta o producción (un vaso para llevar dentro de una receta).
  final double soldQty;
  final double soldValue;

  /// Consumo interno.
  final double usedQty;
  final double usedValue;

  final double brokenQty;
  final double brokenValue;

  /// Faltante / robo.
  final double lostQty;
  final double lostValue;

  /// Vencido, limpieza, donación, sin motivo.
  final double otherOutQty;
  final double otherOutValue;

  /// Diferencias de conteo. Negativo = faltó al contar sin que nadie
  /// reportara la rotura.
  final double countAdjustQty;
  final double countAdjustValue;

  final List<SupplyWarehouseStock> byWarehouse;

  bool get isSmallware => classification == ItemClassification.smallware;

  /// Lo que se USÓ: consumo interno + lo que salió con las ventas.
  double get consumedQty => usedQty + soldQty;
  double get consumedValue => usedValue + soldValue;

  /// Lo que se PERDIÓ: roturas, faltantes, otras salidas y lo que faltó en
  /// el conteo.
  double get lossQty =>
      brokenQty +
      lostQty +
      otherOutQty +
      (countAdjustQty < 0 ? -countAdjustQty : 0);
  double get lossValue =>
      brokenValue +
      lostValue +
      otherOutValue +
      (countAdjustValue < 0 ? -countAdjustValue : 0);

  /// Faltante del menaje fuera de las roturas: robo + lo que faltó al contar.
  double get missingQty => lostQty + (countAdjustQty < 0 ? -countAdjustQty : 0);
  double get missingValue =>
      lostValue + (countAdjustValue < 0 ? -countAdjustValue : 0);

  double get stockValue => stock > 0 ? stock * unitCost : 0;

  /// Con mínimo configurado y en o por debajo de él (la misma regla que las
  /// alertas de stock). En el menaje el mínimo es el PAR: tener justo las
  /// piezas que debe haber no es estar corto.
  bool get belowMin =>
      minStock > 0 && (isSmallware ? stock < minStock : stock <= minStock);

  /// Cuánto falta para llegar al par / mínimo.
  double get missingToMin {
    final gap = minStock - stock;
    return gap > 0 ? gap : 0;
  }

  /// Consumo promedio por día en un período de [days] días.
  double dailyUse(int days) => days <= 0 ? 0 : consumedQty / days;

  /// Para cuántos días alcanza lo que hay, al ritmo del período. `null` si no
  /// se usó nada (no hay ritmo con que medir).
  double? daysLeft(int days) {
    final daily = dailyUse(days);
    if (daily <= 0) return null;
    return stock <= 0 ? 0 : stock / daily;
  }

  /// Necesita atención: bajo el mínimo, o (gastables) se acaba en una
  /// semana o menos.
  bool attention(int days) {
    if (belowMin) return true;
    if (isSmallware) return false;
    final left = daysLeft(days);
    return left != null && left <= 7;
  }

  factory SupplyItem.fromMap(Map<String, dynamic> map) {
    final rawWh = map['by_warehouse'];
    return SupplyItem(
      itemId: map['item_id']?.toString() ?? '',
      name: map['item_name']?.toString() ?? 'Artículo',
      sku: map['item_sku']?.toString() ?? '',
      unit: map['item_unit']?.toString() ?? '',
      classification:
          map['classification']?.toString() ?? ItemClassification.supply,
      unitCost: _num(map['unit_cost']),
      stock: _num(map['stock']),
      minStock: _num(map['min_stock']),
      minFromWarehouse: map['min_source']?.toString() == 'almacen',
      purchasedQty: _num(map['purchased_qty']),
      purchasedValue: _num(map['purchased_value']),
      soldQty: _num(map['sold_qty']),
      soldValue: _num(map['sold_value']),
      usedQty: _num(map['used_qty']),
      usedValue: _num(map['used_value']),
      brokenQty: _num(map['broken_qty']),
      brokenValue: _num(map['broken_value']),
      lostQty: _num(map['lost_qty']),
      lostValue: _num(map['lost_value']),
      otherOutQty: _num(map['other_out_qty']),
      otherOutValue: _num(map['other_out_value']),
      countAdjustQty: _num(map['count_adjust_qty']),
      countAdjustValue: _num(map['count_adjust_value']),
      byWarehouse: [
        if (rawWh is List)
          for (final w in rawWh.whereType<Map>())
            SupplyWarehouseStock.fromMap(Map<String, dynamic>.from(w)),
      ],
    );
  }
}

/// Consumo interno de un área. [destination] `null` = se registró sin área.
class SupplyDestination {
  const SupplyDestination({
    required this.destination,
    required this.value,
    required this.count,
  });

  final String? destination;
  final double value;
  final int count;

  String get label => destination ?? 'Sin área';

  factory SupplyDestination.fromMap(Map<String, dynamic> map) {
    final d = map['destination']?.toString().trim();
    return SupplyDestination(
      destination: d == null || d.isEmpty ? null : d,
      value: _num(map['value']),
      count: _int(map['count']),
    );
  }
}

class SuppliesReport {
  const SuppliesReport({
    this.days = 30,
    this.items = const [],
    this.byDestination = const [],
  });

  final int days;
  final List<SupplyItem> items;
  final List<SupplyDestination> byDestination;

  List<SupplyItem> get supplies =>
      items.where((i) => !i.isSmallware).toList(growable: false);
  List<SupplyItem> get smallware =>
      items.where((i) => i.isSmallware).toList(growable: false);

  factory SuppliesReport.fromMap(Map<String, dynamic> map) {
    final rawItems = map['items'];
    final rawDest = map['by_destination'];
    return SuppliesReport(
      days: _int(map['days']) <= 0 ? 30 : _int(map['days']),
      items: [
        if (rawItems is List)
          for (final i in rawItems.whereType<Map>())
            SupplyItem.fromMap(Map<String, dynamic>.from(i)),
      ],
      byDestination: [
        if (rawDest is List)
          for (final d in rawDest.whereType<Map>())
            SupplyDestination.fromMap(Map<String, dynamic>.from(d)),
      ],
    );
  }
}

class SuppliesWarehouseOption {
  const SuppliesWarehouseOption(this.id, this.name);
  final String id;
  final String name;
}

class SuppliesState {
  const SuppliesState({
    this.loading = false,
    this.error,
    this.missingFunction = false,
    this.businessId,
    this.warehouses = const [],
    this.warehouseId,
    this.daysBack = 30,
    this.tab = SuppliesTab.supplies,
    this.search = '',
    this.onlyAttention = false,
    this.report = const SuppliesReport(),
  });

  final bool loading;
  final String? error;

  /// El servidor no tiene `fn_inventory_supplies_overview`.
  final bool missingFunction;
  final String? businessId;
  final List<SuppliesWarehouseOption> warehouses;
  final String? warehouseId;
  final int daysBack;
  final SuppliesTab tab;
  final String search;

  /// Solo lo que hay que reponer.
  final bool onlyAttention;
  final SuppliesReport report;

  List<SupplyItem> get tabItems =>
      tab == SuppliesTab.smallware ? report.smallware : report.supplies;

  /// Lo que se ve en la tabla: pestaña + búsqueda + «por reponer». Primero lo
  /// que necesita atención, después lo que más se va (uso o pérdida).
  List<SupplyItem> get visibleItems {
    final q = search.trim().toLowerCase();
    final list = tabItems
        .where(
          (i) =>
              q.isEmpty ||
              i.name.toLowerCase().contains(q) ||
              i.sku.toLowerCase().contains(q),
        )
        .where((i) => !onlyAttention || i.attention(report.days))
        .toList();
    final smallware = tab == SuppliesTab.smallware;
    list.sort((a, b) {
      final att =
          (b.attention(report.days) ? 1 : 0) -
          (a.attention(report.days) ? 1 : 0);
      if (att != 0) return att;
      final byValue = smallware
          ? b.lossValue.compareTo(a.lossValue)
          : b.consumedValue.compareTo(a.consumedValue);
      if (byValue != 0) return byValue;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  int get attentionCount =>
      tabItems.where((i) => i.attention(report.days)).length;

  SuppliesState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    bool? missingFunction,
    String? businessId,
    List<SuppliesWarehouseOption>? warehouses,
    String? warehouseId,
    bool clearWarehouse = false,
    int? daysBack,
    SuppliesTab? tab,
    String? search,
    bool? onlyAttention,
    SuppliesReport? report,
  }) {
    return SuppliesState(
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      missingFunction: missingFunction ?? this.missingFunction,
      businessId: businessId ?? this.businessId,
      warehouses: warehouses ?? this.warehouses,
      warehouseId: clearWarehouse ? null : (warehouseId ?? this.warehouseId),
      daysBack: daysBack ?? this.daysBack,
      tab: tab ?? this.tab,
      search: search ?? this.search,
      onlyAttention: onlyAttention ?? this.onlyAttention,
      report: report ?? this.report,
    );
  }
}
