import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';

Order _order({
  double subtotal = 0,
  double discounts = 0,
  double serviceFee = 0,
  double tax = 0,
  double total = 0,
  double deliveryFee = 0,
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
    deliveryFee: deliveryFee,
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
      // PRD 2.5: bajo el modelo unificado, oi.tax incluye TODOS los impuestos
      // (regulares + service fees) que apliquen al origin. order.serviceFee = 0.
      // Modifiers POR UNIDAD (fix 20260509_0004): 2 × (100 + 2 × 14) = 256 base.
      // Tax 28% = 71.68.
      final order = _order(subtotal: 256, tax: 71.68);
      final item = _item(
        id: 'mods',
        quantity: 2,
        unitPrice: 100,
        subtotal: 256, // base + modifiers por unidad (consolidado por backend)
        tax: 71.68, // 28% de 256
        total: 327.68,
        taxMode: 'exclusive',
        taxRate: 28,
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

      expect(itemDisplayTotal(order, item), 256.0); // gross sin tax
      expect(summary.subtotal, 256.0);
      expect(summary.tax, 71.68);
      expect(summary.serviceFee, 0.0); // PRD 2.5: siempre 0
      expect(summary.total, 327.68);
    });

    test('exclusive discount is subtracted exactly once (no double count)', () {
      // Regresión del bug del descuento doble (mig 20260630_0001): el trigger
      // backend DEBE guardar oi.subtotal como base PRE-descuento. Bajo ese
      // contrato, un 20% sobre un item exclusive de RD$295 @ 28% (10% Ley +
      // 18% ITBIS) descuenta 75.52 (= 20% de 377.60) y el total queda en
      // 302.08 — NO 205.42 (que sería restar el descuento dos veces).
      final order = _order(
        subtotal: 295,
        tax: 82.60,
        discounts: 75.52,
        total: 302.08,
      );
      final item = _item(
        id: 'disc',
        quantity: 1,
        unitPrice: 295,
        subtotal: 295, // base pre-descuento (contrato del backend)
        tax: 82.60, // 28% de 295
        discounts: 75.52, // 20% de (295 + 82.60)
        total: 302.08,
        taxMode: 'exclusive',
        taxRate: 28,
      );

      final summary = summarizeOrderPricing(order, [item]);

      expect(summary.subtotal, 295.0);
      expect(summary.tax, 82.60);
      expect(summary.discounts, 75.52);
      expect(summary.total, 302.08); // descuento restado UNA vez
      // El precio mostrado en la línea es gross − descuento.
      expect(itemDisplayTotal(order, item), closeTo(219.48, 0.001));
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

    // PRD 2.5: este test validaba la absorción de centavo del modelo viejo
    // (cuando inclusive math se hacía en frontend con dos tasas separadas).
    // Bajo PRD 2.5, el backend entrega oi.subtotal/oi.tax exactos y el frontend
    // los confía sin re-extraer. El test queda como deuda hasta rediseñarlo
    // contra el nuevo flujo (entrada: items consolidados, expectation: sin
    // residual porque el backend ya cuadra).
    test('inclusive breakdown closes exact 300.00 by absorbing residual in base', skip: 'PRD 2.5 deprecó la absorción frontend del centavo. Rediseñar test.', () {
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

  group('red de seguridad de descuento (anti sobre-descuento)', () {
    test('descuento > monto de línea se capa → total nunca negativo', () {
      final order = _order(subtotal: 825);
      final item = _item(
        id: 'overdisc',
        quantity: 3,
        unitPrice: 275,
        subtotal: 825,
        tax: 0,
        total: 825,
        discounts: 900, // promo mal: descuento mayor que el gross de la línea
      );
      final summary = summarizeOrderPricing(order, [item]);
      expect(summary.discounts, 825); // capado al gross
      expect(summary.total, 0); // nunca negativo / sub-cobro
    });

    test('descuento correcto (1 de 3 unidades gratis) no se toca', () {
      // 4x3 sobre fila qty=3 @ 275 = gross 825; 1 unidad gratis = -275.
      final order = _order(subtotal: 825);
      final item = _item(
        id: 'partial',
        quantity: 3,
        unitPrice: 275,
        subtotal: 825,
        tax: 0,
        total: 550,
        discounts: 275,
      );
      final summary = summarizeOrderPricing(order, [item]);
      expect(summary.discounts, 275);
      expect(summary.total, 550);
    });
  });

  group('fee de delivery propio (cargo exento)', () {
    test('suma el fee al total DESPUÉS de impuestos, sin tocar subtotal/tax', () {
      // Item exclusivo RD$100 + ITBIS 18% = 118. Fee de delivery RD$50 exento.
      final order = _order(deliveryFee: 50);
      final item = _item(
        id: 'excl',
        quantity: 1,
        unitPrice: 100,
        subtotal: 100,
        tax: 18,
        total: 118,
        taxRate: 18,
      );

      final summary = summarizeOrderPricing(order, [item]);

      expect(summary.subtotal, 100); // base sin tocar
      expect(summary.tax, 18); // ITBIS sin tocar
      expect(summary.deliveryFee, 50); // expuesto aparte
      expect(summary.total, 168); // 118 + 50 exento
    });

    test('fee 0 no altera el total (no regresión para no-delivery)', () {
      final order = _order();
      final item = _item(
        id: 'excl',
        quantity: 1,
        unitPrice: 100,
        subtotal: 100,
        tax: 18,
        total: 118,
        taxRate: 18,
      );

      final summary = summarizeOrderPricing(order, [item]);

      expect(summary.deliveryFee, 0);
      expect(summary.total, 118);
    });

    test('fee se suma sobre el gross de una orden 100% inclusive', () {
      // Item inclusive catálogo RD$500 (anclado al gross). Fee RD$100.
      final order = _order(deliveryFee: 100);
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

      expect(summary.total, 600); // 500 gross + 100 exento
      expect(summary.deliveryFee, 100);
    });
  });
}
