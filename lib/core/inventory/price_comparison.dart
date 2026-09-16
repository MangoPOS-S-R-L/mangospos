/// Comparador de precios (Compras F4).
///
/// Lee `fn_purchase_price_comparison` (20260915_0008): por insumo × suplidor,
/// el costo REAL recibido (último, anterior distinto, promedio, mín/máx) y el
/// precio de lista. Aquí va lo que decide la pantalla: si hay un suplidor
/// claramente más barato que el que se está usando (D3: se SUGIERE, no se
/// cambia solo) y cómo leer la tendencia.
///
/// Funciones puras.
library;

double? _opt(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());

String? _str(dynamic v) {
  final s = v?.toString().trim();
  return (s == null || s.isEmpty) ? null : s;
}

class SupplierPrice {
  final String itemId;
  final String supplierId;
  final String supplierName;
  final bool supplierActive;

  /// Compras y cantidad (unidad base) dentro de la ventana.
  final int purchasesCount;
  final double quantityTotal;

  /// Costos por UNIDAD BASE.
  final double? lastCostBase;
  final DateTime? lastAt;
  final double? previousCostBase;

  /// Último vs. anterior distinto, en %.
  final double? trendPct;
  final double? avgCostBase;
  final double? minCostBase;
  final double? maxCostBase;

  /// Presentación para mostrar por empaque.
  final String purchaseUnit;
  final double packSize;

  /// Precio de lista (por unidad de compra), de cuándo y de dónde.
  final double? listPricePack;
  final double? listPriceBase;
  final DateTime? listPriceAt;

  /// 'recepcion' | 'manual' | null.
  final String? listPriceSource;
  final bool isLinked;
  final bool linkActive;

  /// Es el suplidor que usa el pedido sugerido.
  final bool isResolved;

  /// 1 = el más barato por último costo. Null sin compras.
  final int? rankByLast;

  /// Cuánto más caro que el más barato, en %. 0 el más barato.
  final double? vsCheapestPct;

  const SupplierPrice({
    required this.itemId,
    required this.supplierId,
    required this.supplierName,
    this.supplierActive = true,
    this.purchasesCount = 0,
    this.quantityTotal = 0,
    this.lastCostBase,
    this.lastAt,
    this.previousCostBase,
    this.trendPct,
    this.avgCostBase,
    this.minCostBase,
    this.maxCostBase,
    this.purchaseUnit = '',
    this.packSize = 1,
    this.listPricePack,
    this.listPriceBase,
    this.listPriceAt,
    this.listPriceSource,
    this.isLinked = false,
    this.linkActive = false,
    this.isResolved = false,
    this.rankByLast,
    this.vsCheapestPct,
  });

  factory SupplierPrice.fromMap(Map<String, dynamic> map) {
    final pack = _opt(map['pack_size']);
    return SupplierPrice(
      itemId: map['item_id']?.toString() ?? '',
      supplierId: map['supplier_id']?.toString() ?? '',
      supplierName: _str(map['supplier_name']) ?? 'Suplidor',
      supplierActive: map['supplier_active'] != false,
      purchasesCount: (_opt(map['purchases_count']) ?? 0).round(),
      quantityTotal: _opt(map['quantity_total']) ?? 0,
      lastCostBase: _opt(map['last_cost_base']),
      lastAt: _date(map['last_at']),
      previousCostBase: _opt(map['previous_cost_base']),
      trendPct: _opt(map['trend_pct']),
      avgCostBase: _opt(map['avg_cost_base']),
      minCostBase: _opt(map['min_cost_base']),
      maxCostBase: _opt(map['max_cost_base']),
      purchaseUnit: _str(map['purchase_unit']) ?? '',
      packSize: (pack == null || pack <= 0) ? 1 : pack,
      listPricePack: _opt(map['list_price_pack']),
      listPriceBase: _opt(map['list_price_base']),
      listPriceAt: _date(map['list_price_at']),
      listPriceSource: _str(map['list_price_source']),
      isLinked: map['is_linked'] == true,
      linkActive: map['link_active'] == true,
      isResolved: map['is_resolved'] == true,
      rankByLast: _opt(map['rank_by_last'])?.round(),
      vsCheapestPct: _opt(map['vs_cheapest_pct']),
    );
  }

  bool get hasPack => (packSize - 1).abs() > 1e-9;

  /// Costo por empaque a partir de un costo base.
  double? perPack(double? base) => base == null ? null : base * packSize;
}

Map<String, List<SupplierPrice>> groupPricesByItem(Iterable<SupplierPrice> prices) {
  final result = <String, List<SupplierPrice>>{};
  for (final p in prices) {
    result.putIfAbsent(p.itemId, () => []).add(p);
  }
  return result;
}

/// Un suplidor más barato que el actual.
class CheaperSupplier {
  final SupplierPrice cheaper;
  final SupplierPrice current;

  /// Cuánto se ahorra por unidad base, en % del costo actual.
  final double savingPct;

  const CheaperSupplier({
    required this.cheaper,
    required this.current,
    required this.savingPct,
  });
}

/// El suplidor activo más barato por ÚLTIMO costo real, si le gana al actual
/// por al menos [minGapPct] y su precio no es más viejo que [maxAgeDays]. Un
/// precio de hace un año no justifica cambiar de suplidor. Null si el actual
/// no tiene compras (no hay contra qué comparar) o no hay alternativa.
CheaperSupplier? cheaperAlternative(
  List<SupplierPrice> prices, {
  required String? currentSupplierId,
  double minGapPct = 5,
  int maxAgeDays = 90,
  DateTime? now,
}) {
  if (currentSupplierId == null) return null;
  SupplierPrice? current;
  for (final p in prices) {
    if (p.supplierId == currentSupplierId) current = p;
  }
  final currentCost = current?.lastCostBase;
  if (current == null || currentCost == null || currentCost <= 0) return null;

  final limit = (now ?? DateTime.now()).subtract(Duration(days: maxAgeDays));
  SupplierPrice? best;
  for (final p in prices) {
    final cost = p.lastCostBase;
    if (p.supplierId == currentSupplierId || !p.supplierActive || cost == null) continue;
    if (p.lastAt == null || p.lastAt!.isBefore(limit)) continue;
    if (best == null || cost < best.lastCostBase!) best = p;
  }
  if (best == null) return null;
  final saving = (currentCost - best.lastCostBase!) / currentCost * 100;
  if (saving < minGapPct) return null;
  return CheaperSupplier(cheaper: best, current: current, savingPct: saving);
}

/// «▲ 10.5%», «▼ 3%», «=» o vacío sin dato.
String trendLabel(double? pct) {
  if (pct == null) return '';
  if (pct.abs() < 0.05) return '=';
  final rounded = pct.abs() >= 10
      ? pct.abs().toStringAsFixed(0)
      : pct.abs().toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  return '${pct > 0 ? '▲' : '▼'} $rounded%';
}
