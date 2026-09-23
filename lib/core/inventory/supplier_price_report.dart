/// Reporte «¿Quién me vende más barato?» (Compras F4, vista de Reportes).
///
/// Toma las filas de `fn_purchase_price_comparison` (insumo × suplidor, del
/// costo REAL recibido) y las arma POR INSUMO: quién es el más barato, a quién
/// se le está comprando, cuánto más caro sale y cuánto se habría ahorrado en la
/// ventana comprándole todo al más barato.
///
/// Reglas que NO se negocian acá:
/// - El «más barato» solo puede ser un suplidor ACTIVO y con compras DENTRO de
///   la ventana. Un suplidor inactivo no es una opción real, y `last_cost` del
///   RPC es la última compra de SIEMPRE: sin este filtro, un precio de hace dos
///   años se colaría como «el más barato». `purchases_count` sí está acotado a
///   la ventana, así que es él quien decide si la fila cuenta.
/// - El ahorro es de la VENTANA que se está mirando: cantidad comprada por lo
///   que se pagó de más contra el precio más barato. Es una estimación para
///   priorizar, no una cuenta por cobrar.
/// - El sistema SUGIERE (D3 del PRD): acá no se cambia ningún suplidor.
///
/// Funciones puras: sin Supabase, sin Flutter.
library;

import 'package:mangopos/core/inventory/price_comparison.dart';

/// Nombre y unidad base de un insumo, para rotular la fila.
class SupplierPriceItemInfo {
  final String name;
  final String unit;

  const SupplierPriceItemInfo({required this.name, this.unit = ''});
}

/// Una fila del reporte: un insumo con todos sus suplidores.
class SupplierPriceReportRow {
  final String itemId;
  final String itemName;

  /// Unidad BASE del insumo (los costos son por unidad base).
  final String unit;

  /// Todos los suplidores del insumo en la ventana, los que tienen costo
  /// primero y de más barato a más caro.
  final List<SupplierPrice> prices;

  /// Suplidor activo con el ÚLTIMO costo más bajo. Null si nadie tiene costo.
  final SupplierPrice? cheapest;

  /// A quién se le está comprando: el del pedido sugerido (`is_resolved`) y,
  /// si no hay, el de la compra más reciente.
  final SupplierPrice? current;

  /// Suplidores con compras (y costo real) DENTRO de la ventana.
  final int suppliersWithCost;

  /// Cantidad comprada en la ventana (unidad base), todos los suplidores.
  final double totalQty;

  /// Lo que se pagó en la ventana (promedio ponderado × cantidad).
  final double totalSpent;

  /// Cuánto más caro está el actual contra el más barato, en % del actual.
  /// Null si no hay con qué comparar o si el actual YA es el más barato.
  final double? gapPct;

  /// Lo que se habría ahorrado comprándole todo al más barato.
  final double potentialSaving;

  const SupplierPriceReportRow({
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.prices,
    required this.cheapest,
    required this.current,
    required this.suppliersWithCost,
    required this.totalQty,
    required this.totalSpent,
    required this.gapPct,
    required this.potentialSaving,
  });

  /// Hay una opción más barata que a quien se le compra hoy.
  bool get hasCheaperOption =>
      cheapest != null &&
      current != null &&
      cheapest!.supplierId != current!.supplierId &&
      (gapPct ?? 0) > 0;

  /// Se le compra a más de un suplidor: el precio se puede negociar.
  bool get hasAlternatives => suppliersWithCost > 1;
}

double _costOf(SupplierPrice p) => p.lastCostBase ?? double.infinity;

/// El precio sirve para comparar: hay costo y hay compras DENTRO de la ventana.
/// Un vínculo sin compras o una compra vieja no entran.
bool _comparable(SupplierPrice p) =>
    p.purchasesCount > 0 && p.lastCostBase != null && p.lastCostBase! > 0;

/// El suplidor ACTIVO más barato por último costo. Null si ninguno tiene costo.
SupplierPrice? cheapestSupplier(List<SupplierPrice> prices) {
  SupplierPrice? best;
  for (final p in prices) {
    if (!p.supplierActive || !_comparable(p)) continue;
    if (best == null || p.lastCostBase! < best.lastCostBase!) best = p;
  }
  return best;
}

/// A quién se le compra hoy: el del pedido sugerido, o el de la compra más
/// reciente. Null si nadie tiene costo.
SupplierPrice? currentSupplier(List<SupplierPrice> prices) {
  for (final p in prices) {
    if (p.isResolved && _comparable(p)) return p;
  }
  SupplierPrice? latest;
  for (final p in prices) {
    if (!_comparable(p) || p.lastAt == null) continue;
    if (latest == null || p.lastAt!.isAfter(latest.lastAt!)) latest = p;
  }
  return latest;
}

/// Arma las filas del reporte. Solo insumos con al menos un precio.
List<SupplierPriceReportRow> buildSupplierPriceReport({
  required Iterable<SupplierPrice> prices,
  Map<String, SupplierPriceItemInfo> items = const {},
}) {
  final byItem = groupPricesByItem(prices);
  final rows = <SupplierPriceReportRow>[];

  for (final entry in byItem.entries) {
    // Solo suplidores con compras en la ventana: son los únicos comparables.
    final itemPrices = entry.value.where(_comparable).toList()
      ..sort((a, b) {
        final byCost = _costOf(a).compareTo(_costOf(b));
        if (byCost != 0) return byCost;
        return a.supplierName.toLowerCase().compareTo(
          b.supplierName.toLowerCase(),
        );
      });
    if (itemPrices.isEmpty) continue;

    final cheapest = cheapestSupplier(itemPrices);
    final current = currentSupplier(itemPrices);

    var totalQty = 0.0;
    var totalSpent = 0.0;
    var withCost = 0;
    for (final p in itemPrices) {
      final cost = p.avgCostBase ?? p.lastCostBase;
      withCost++;
      if (p.quantityTotal <= 0 || cost == null || cost <= 0) continue;
      totalQty += p.quantityTotal;
      totalSpent += cost * p.quantityTotal;
    }

    double? gapPct;
    if (cheapest != null &&
        current != null &&
        cheapest.supplierId != current.supplierId) {
      final currentCost = current.lastCostBase!;
      if (currentCost > 0) {
        gapPct = (currentCost - cheapest.lastCostBase!) / currentCost * 100;
      }
    }

    var saving = 0.0;
    if (cheapest != null && totalQty > 0) {
      saving = totalSpent - cheapest.lastCostBase! * totalQty;
      if (saving < 0) saving = 0;
    }

    final info = items[entry.key];
    rows.add(
      SupplierPriceReportRow(
        itemId: entry.key,
        itemName: info?.name.trim().isNotEmpty == true
            ? info!.name.trim()
            : 'Insumo sin nombre',
        unit: info?.unit.trim() ?? '',
        prices: List.unmodifiable(itemPrices),
        cheapest: cheapest,
        current: current,
        suppliersWithCost: withCost,
        totalQty: totalQty,
        totalSpent: totalSpent,
        gapPct: gapPct,
        potentialSaving: saving,
      ),
    );
  }

  return sortSupplierPriceRows(rows);
}

/// Primero donde hay plata sobre la mesa: mayor ahorro, luego mayor diferencia
/// de precio, luego alfabético para que el orden sea estable.
List<SupplierPriceReportRow> sortSupplierPriceRows(
  List<SupplierPriceReportRow> rows,
) {
  final sorted = [...rows]..sort((a, b) {
    final bySaving = b.potentialSaving.compareTo(a.potentialSaving);
    if (bySaving != 0) return bySaving;
    final byGap = (b.gapPct ?? 0).compareTo(a.gapPct ?? 0);
    if (byGap != 0) return byGap;
    return a.itemName.toLowerCase().compareTo(b.itemName.toLowerCase());
  });
  return sorted;
}

/// Filtra por texto (insumo o suplidor) y, opcionalmente, deja solo los
/// insumos con más de un suplidor con precio.
List<SupplierPriceReportRow> filterSupplierPriceRows(
  List<SupplierPriceReportRow> rows, {
  String query = '',
  bool onlyWithAlternatives = false,
}) {
  final q = query.trim().toLowerCase();
  return rows.where((row) {
    if (onlyWithAlternatives && !row.hasAlternatives) return false;
    if (q.isEmpty) return true;
    if (row.itemName.toLowerCase().contains(q)) return true;
    return row.prices.any((p) => p.supplierName.toLowerCase().contains(q));
  }).toList(growable: false);
}

/// Los números de la cabecera del reporte.
class SupplierPriceReportSummary {
  /// Insumos con al menos una compra con suplidor en la ventana.
  final int itemsCompared;

  /// Insumos a los que se les compra a 2 o más suplidores.
  final int itemsWithAlternatives;

  /// Insumos donde hay alguien más barato que el suplidor actual.
  final int itemsWithCheaperOption;

  /// Suma del ahorro estimado de la ventana.
  final double totalSaving;

  /// Suplidores distintos con compras en la ventana.
  final int suppliers;

  const SupplierPriceReportSummary({
    required this.itemsCompared,
    required this.itemsWithAlternatives,
    required this.itemsWithCheaperOption,
    required this.totalSaving,
    required this.suppliers,
  });

  static const empty = SupplierPriceReportSummary(
    itemsCompared: 0,
    itemsWithAlternatives: 0,
    itemsWithCheaperOption: 0,
    totalSaving: 0,
    suppliers: 0,
  );
}

SupplierPriceReportSummary summarizeSupplierPriceReport(
  List<SupplierPriceReportRow> rows,
) {
  final suppliers = <String>{};
  var withAlternatives = 0;
  var withCheaper = 0;
  var saving = 0.0;
  for (final row in rows) {
    if (row.hasAlternatives) withAlternatives++;
    if (row.hasCheaperOption) withCheaper++;
    saving += row.potentialSaving;
    for (final p in row.prices) {
      suppliers.add(p.supplierId);
    }
  }
  return SupplierPriceReportSummary(
    itemsCompared: rows.length,
    itemsWithAlternatives: withAlternatives,
    itemsWithCheaperOption: withCheaper,
    totalSaving: saving,
    suppliers: suppliers.length,
  );
}
