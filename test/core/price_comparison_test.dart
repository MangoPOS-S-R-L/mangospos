import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/inventory/price_comparison.dart';

final _now = DateTime(2026, 9, 15, 12);

SupplierPrice _price(
  String supplier, {
  double? last,
  int daysAgo = 3,
  bool active = true,
  String item = 'refresco',
}) =>
    SupplierPrice(
      itemId: item,
      supplierId: supplier,
      supplierName: supplier.toUpperCase(),
      supplierActive: active,
      lastCostBase: last,
      lastAt: last == null ? null : _now.subtract(Duration(days: daysAgo)),
      purchaseUnit: 'Caja',
      packSize: 24,
    );

void main() {
  test('fromMap lee números como texto, fechas y banderas', () {
    final p = SupplierPrice.fromMap({
      'item_id': 'i',
      'supplier_id': 's',
      'supplier_name': 'SA',
      'supplier_active': true,
      'purchases_count': 4,
      'quantity_total': '120',
      'last_cost_base': '21.0000',
      'last_at': '2026-09-15T10:00:00+00:00',
      'previous_cost_base': 23,
      'trend_pct': '-8.7',
      'pack_size': 24,
      'purchase_unit': 'Caja',
      'list_price_pack': 504,
      'list_price_source': 'recepcion',
      'is_linked': true,
      'link_active': true,
      'is_resolved': true,
      'rank_by_last': 1,
      'vs_cheapest_pct': 0,
    });
    expect(p.lastCostBase, 21);
    expect(p.quantityTotal, 120);
    expect(p.trendPct, -8.7);
    expect(p.lastAt, isNotNull);
    expect(p.perPack(p.lastCostBase), 504);
    expect(p.rankByLast, 1);
    expect(p.isResolved && p.linkActive, isTrue);
  });

  group('cheaperAlternative', () {
    test('sugiere el más barato activo y reciente si ahorra al menos 5%', () {
      final alt = cheaperAlternative(
        [_price('sa', last: 25), _price('sb', last: 22), _price('sc', last: 21, daysAgo: 200)],
        currentSupplierId: 'sa',
        now: _now,
      );
      expect(alt, isNotNull);
      expect(alt!.cheaper.supplierId, 'sb', reason: 'sc es más barato pero su precio es de hace 200 días');
      expect(alt.savingPct, closeTo(12, 1e-9));
    });

    test('no sugiere por diferencias chicas, suplidores inactivos ni sin compras propias', () {
      expect(
        cheaperAlternative([_price('sa', last: 22), _price('sb', last: 21.5)], currentSupplierId: 'sa', now: _now),
        isNull,
      );
      expect(
        cheaperAlternative([_price('sa', last: 25), _price('sb', last: 10, active: false)], currentSupplierId: 'sa', now: _now),
        isNull,
      );
      expect(
        cheaperAlternative([_price('sa'), _price('sb', last: 10)], currentSupplierId: 'sa', now: _now),
        isNull,
      );
      expect(cheaperAlternative([_price('sb', last: 10)], currentSupplierId: null, now: _now), isNull);
    });

    test('si el actual ya es el más barato no hay sugerencia', () {
      expect(
        cheaperAlternative([_price('sa', last: 20), _price('sb', last: 22)], currentSupplierId: 'sa', now: _now),
        isNull,
      );
    });
  });

  test('agrupa por insumo', () {
    final grouped = groupPricesByItem([
      _price('sa', last: 1),
      _price('sb', last: 2),
      _price('sa', last: 3, item: 'queso'),
    ]);
    expect(grouped['refresco']!.length, 2);
    expect(grouped['queso']!.single.lastCostBase, 3);
  });

  test('trendLabel', () {
    expect(trendLabel(null), '');
    expect(trendLabel(0.01), '=');
    expect(trendLabel(10.46), '▲ 10%');
    expect(trendLabel(-8.7), '▼ 8.7%');
    expect(trendLabel(3.0), '▲ 3%');
  });
}
