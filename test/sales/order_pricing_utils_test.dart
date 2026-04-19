import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';

Order _order({
  double subtotal = 0,
  double discounts = 0,
  double serviceFee = 0,
  double tax = 0,
  double total = 0,
}) {
  return Order(
    id: 'order-1',
    sessionId: 'session-1',
    status: 'open',
    subtotal: subtotal,
    discounts: discounts,
    serviceFee: serviceFee,
    tax: tax,
    total: total,
    createdAt: DateTime(2026, 1, 1),
  );
}

OrderItem _item({
  required String id,
  required double quantity,
  required double unitPrice,
  required double subtotal,
  required double tax,
  required double total,
  double discounts = 0,
  bool isTakeout = false,
  String taxMode = 'exclusive',
  double taxRate = 0,
  double? originalTaxRate,
  List<OrderItemModifier> modifiers = const [],
}) {
  return OrderItem(
    id: id,
    orderId: 'order-1',
    productName: 'Item $id',
    quantity: quantity,
    unitPrice: unitPrice,
    subtotal: subtotal,
    discounts: discounts,
    tax: tax,
    total: total,
    isTakeout: isTakeout,
    status: 'pending',
    taxMode: taxMode,
    taxRate: taxRate,
    originalTaxRate: originalTaxRate,
    createdAt: DateTime(2026, 1, 1),
    modifiers: modifiers,
  );
}

void main() {
  group('order pricing reconciliation', () {
    test('inclusive item keeps clean catalog total without one-cent drift', () {
      final order = _order(subtotal: 390.63, serviceFee: 39.06);
      final item = _item(
        id: 'inclusive',
        quantity: 1,
        unitPrice: 500,
        subtotal: 390.63,
        tax: 70.31,
        total: 500,
        taxMode: 'inclusive',
        taxRate: 18,
        originalTaxRate: 28,
      );

      final summary = summarizeOrderPricing(order, [item]);

      expect(itemDisplayTotal(order, item), 500.0);
      expect(itemDisplayUnitPrice(order, item), 500.0);
      expect(summary.total, 500.0);
      expect(summary.tax, closeTo(70.31, 0.001));
      expect(summary.serviceFee, closeTo(39.06, 0.001));
    });

    test('modifier totals reconcile through the canonical summary path', () {
      final order = _order(subtotal: 200, serviceFee: 20);
      final item = _item(
        id: 'mods',
        quantity: 2,
        unitPrice: 100,
        subtotal: 200,
        tax: 36,
        total: 256,
        taxMode: 'exclusive',
        taxRate: 18,
        modifiers: const [
          OrderItemModifier(
            id: 'm1',
            itemId: 'mods',
            name: 'Extra queso',
            qty: 2,
            price: 14,
          ),
        ],
      );

      final summary = summarizeOrderPricing(order, [item]);

      expect(itemDisplayTotal(order, item), 283.8);
      expect(summary.subtotal, 228.0);
      expect(summary.tax, 41.04);
      expect(summary.serviceFee, 22.8);
      expect(summary.total, 291.84);
    });

    test(
      'configured tax breakdown falls back when it no longer reconciles',
      () {
        final order = _order(subtotal: 423.73, tax: 76.27, total: 500);
        final item = _item(
          id: 'delivery',
          quantity: 1,
          unitPrice: 500,
          subtotal: 423.73,
          tax: 76.27,
          total: 500,
          taxMode: 'inclusive',
          taxRate: 18,
          originalTaxRate: 18,
        );

        final breakdown = buildOrderTaxBreakdown(
          order,
          [item],
          configuredBreakdown: const [
            (label: 'ITBIS (18%)', amount: 76.27),
            (label: 'Propina Ley (10%)', amount: 42.37),
          ],
        );

        expect(breakdown.length, 1);
        expect(breakdown.first.label, contains('ITBIS'));
        expect(breakdown.first.amount, 76.27);
      },
    );

    test(
      'configured tax breakdown is reconciled to summary by one cent when safe',
      () {
        final order = _order(
          subtotal: 100,
          tax: 18,
          serviceFee: 10,
          total: 128,
        );
        final item = _item(
          id: 'rounding',
          quantity: 1,
          unitPrice: 100,
          subtotal: 100,
          tax: 18,
          total: 128,
          taxMode: 'exclusive',
          taxRate: 18,
        );

        final breakdown = buildOrderTaxBreakdown(
          order,
          [item],
          configuredBreakdown: const [
            (label: 'ITBIS (18%)', amount: 18),
            (label: 'Propina Ley (10%)', amount: 9.99),
          ],
        );

        final sum = breakdown.fold<double>(
          0,
          (acc, entry) => acc + entry.amount,
        );
        expect(sum, 28.0);
        expect(breakdown.last.amount, 10.0);
      },
    );

    test('inclusive breakdown closes exact 300.00 by absorbing residual in base', () {
      final order = _order(
        subtotal: 234.37,
        tax: 42.19,
        serviceFee: 23.43,
        total: 300.00,
      );
      final item = _item(
        id: 'inclusive300',
        quantity: 1,
        unitPrice: 300.00,
        subtotal: 234.37,
        tax: 42.19,
        total: 300.00,
        taxMode: 'inclusive',
        taxRate: 18,
        originalTaxRate: 28,
      );

      final summary = summarizeOrderPricing(order, [item]);

      expect(summary.total, 300.00);
      expect(summary.subtotal, 234.37);
      expect(summary.tax, 42.19);
      expect(summary.serviceFee, 23.44);
      expect(summary.subtotal + summary.tax + summary.serviceFee, 300.00);
    });
  });
}
