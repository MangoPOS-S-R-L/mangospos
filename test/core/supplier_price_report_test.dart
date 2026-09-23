import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/inventory/price_comparison.dart';
import 'package:mangopos/core/inventory/supplier_price_report.dart';

final _now = DateTime(2026, 9, 22, 12);

SupplierPrice _price(
  String supplier, {
  required String item,
  double? last,
  double? avg,
  double qty = 0,
  int? purchases,
  int daysAgo = 3,
  bool active = true,
  bool resolved = false,
}) => SupplierPrice(
  itemId: item,
  supplierId: supplier,
  supplierName: supplier.toUpperCase(),
  supplierActive: active,
  // `purchases_count` del RPC está acotado a la ventana: 0 = no le compraste
  // en estos días, aunque tenga un último costo de hace meses.
  purchasesCount: purchases ?? (qty > 0 ? 1 : 0),
  quantityTotal: qty,
  avgCostBase: avg,
  lastCostBase: last,
  lastAt: last == null ? null : _now.subtract(Duration(days: daysAgo)),
  isResolved: resolved,
);

void main() {
  group('buildSupplierPriceReport', () {
    test('marca al más barato y calcula la diferencia contra el actual', () {
      final rows = buildSupplierPriceReport(
        prices: [
          _price('caro', item: 'ron', last: 100, avg: 100, qty: 10, resolved: true),
          _price('barato', item: 'ron', last: 80, avg: 80, qty: 5),
        ],
        items: {'ron': const SupplierPriceItemInfo(name: 'Ron', unit: 'L')},
      );

      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row.itemName, 'Ron');
      expect(row.unit, 'L');
      expect(row.cheapest?.supplierId, 'barato');
      expect(row.current?.supplierId, 'caro');
      expect(row.gapPct, closeTo(20, 0.001));
      expect(row.hasCheaperOption, isTrue);
      expect(row.suppliersWithCost, 2);
      // 10×100 + 5×80 = 1,400 pagados; al más barato serían 15×80 = 1,200.
      expect(row.totalQty, 15);
      expect(row.totalSpent, closeTo(1400, 0.001));
      expect(row.potentialSaving, closeTo(200, 0.001));
    });

    test('un suplidor inactivo no puede ser el más barato', () {
      final rows = buildSupplierPriceReport(
        prices: [
          _price('activo', item: 'x', last: 50, avg: 50, qty: 4, resolved: true),
          _price('muerto', item: 'x', last: 10, avg: 10, qty: 1, active: false),
        ],
      );
      expect(rows.single.cheapest?.supplierId, 'activo');
      expect(rows.single.hasCheaperOption, isFalse);
      expect(rows.single.potentialSaving, 0);
    });

    test('sin `is_resolved` el actual es la compra más reciente', () {
      final rows = buildSupplierPriceReport(
        prices: [
          _price('viejo', item: 'x', last: 90, avg: 90, qty: 3, daysAgo: 40),
          _price('nuevo', item: 'x', last: 95, avg: 95, qty: 2, daysAgo: 2),
        ],
      );
      expect(rows.single.current?.supplierId, 'nuevo');
      expect(rows.single.cheapest?.supplierId, 'viejo');
      expect(rows.single.gapPct, closeTo(5.263, 0.01));
    });

    test('si ya le compra al más barato no hay a quién cambiarse, pero el '
        'ahorro cuenta lo que se compró más caro', () {
      final rows = buildSupplierPriceReport(
        prices: [
          _price('barato', item: 'x', last: 40, avg: 40, qty: 8, resolved: true),
          _price('caro', item: 'x', last: 60, avg: 60, qty: 2),
        ],
      );
      final row = rows.single;
      expect(row.hasCheaperOption, isFalse);
      expect(row.hasAlternatives, isTrue);
      expect(row.gapPct, isNull);
      // 8×40 + 2×60 = 440; todo al más barato = 10×40 = 400.
      expect(row.potentialSaving, closeTo(40, 0.001));
    });

    test('un proveedor sin compras en la ventana no entra', () {
      final rows = buildSupplierPriceReport(
        prices: [
          _price('actual', item: 'x', last: 60, avg: 60, qty: 5, resolved: true),
          // Último costo barato, pero de una compra fuera de la ventana.
          _price('viejo', item: 'x', last: 20, qty: 0, daysAgo: 400),
        ],
      );
      final row = rows.single;
      expect(row.suppliersWithCost, 1);
      expect(row.cheapest?.supplierId, 'actual');
      expect(row.hasCheaperOption, isFalse);
      expect(row.potentialSaving, 0);
    });

    test('un insumo sin compras en la ventana no genera fila', () {
      final rows = buildSupplierPriceReport(
        prices: [_price('s', item: 'dormido', last: 12, qty: 0, daysAgo: 400)],
      );
      expect(rows, isEmpty);
    });

    test('un insumo sin nombre no rompe la fila', () {
      final rows = buildSupplierPriceReport(
        prices: [_price('s', item: 'huerfano', last: 5, avg: 5, qty: 1)],
      );
      expect(rows.single.itemName, 'Insumo sin nombre');
      expect(rows.single.unit, '');
    });

    test('ordena por ahorro estimado de mayor a menor', () {
      final rows = buildSupplierPriceReport(
        prices: [
          _price('a', item: 'chico', last: 10, avg: 10, qty: 10, resolved: true),
          _price('b', item: 'chico', last: 9, avg: 9, qty: 1),
          _price('a', item: 'grande', last: 100, avg: 100, qty: 100, resolved: true),
          _price('b', item: 'grande', last: 50, avg: 50, qty: 1),
        ],
        items: {
          'chico': const SupplierPriceItemInfo(name: 'Chico'),
          'grande': const SupplierPriceItemInfo(name: 'Grande'),
        },
      );
      expect(rows.map((r) => r.itemId).toList(), ['grande', 'chico']);
    });
  });

  group('filterSupplierPriceRows', () {
    final rows = buildSupplierPriceReport(
      prices: [
        _price('lapenda', item: 'a', last: 10, avg: 10, qty: 2, resolved: true),
        _price('caribas', item: 'a', last: 8, avg: 8, qty: 1),
        _price('unico', item: 'b', last: 30, avg: 30, qty: 1, resolved: true),
      ],
      items: {
        'a': const SupplierPriceItemInfo(name: 'Cerveza'),
        'b': const SupplierPriceItemInfo(name: 'Hielo'),
      },
    );

    test('busca por nombre de producto', () {
      final found = filterSupplierPriceRows(rows, query: 'hiel');
      expect(found.single.itemId, 'b');
    });

    test('busca también por proveedor', () {
      final found = filterSupplierPriceRows(rows, query: 'carib');
      expect(found.single.itemId, 'a');
    });

    test('deja solo los que tienen alternativa', () {
      final found = filterSupplierPriceRows(rows, onlyWithAlternatives: true);
      expect(found.map((r) => r.itemId), ['a']);
    });
  });

  test('summarizeSupplierPriceReport cuenta oportunidades y proveedores', () {
    final rows = buildSupplierPriceReport(
      prices: [
        _price('a', item: 'x', last: 10, avg: 10, qty: 10, resolved: true),
        _price('b', item: 'x', last: 8, avg: 8, qty: 1),
        _price('c', item: 'y', last: 5, avg: 5, qty: 4, resolved: true),
      ],
      items: {
        'x': const SupplierPriceItemInfo(name: 'X'),
        'y': const SupplierPriceItemInfo(name: 'Y'),
      },
    );
    final summary = summarizeSupplierPriceReport(rows);
    expect(summary.itemsCompared, 2);
    expect(summary.itemsWithAlternatives, 1);
    expect(summary.itemsWithCheaperOption, 1);
    expect(summary.suppliers, 3);
    expect(summary.totalSaving, closeTo(20, 0.001));
  });

  test('sin precios no hay filas', () {
    expect(buildSupplierPriceReport(prices: const []), isEmpty);
    expect(
      summarizeSupplierPriceReport(const []).itemsCompared,
      SupplierPriceReportSummary.empty.itemsCompared,
    );
  });
}
