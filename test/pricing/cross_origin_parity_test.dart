// PRD 2.5 F3 — Tests dorados: paridad cross-origin del motor de pricing.
//
// Premisa de PRD 2.5: el modelo unificado pone TODOS los impuestos en
// `oi.tax_rate` y `oi.tax_lines`. `orders.service_fee` siempre = 0.
// El backend filtra por `apply_on_<origin>` al insertar items.
//
// Lo que prueban estos tests:
//   - Para items idénticos (mismas tax_lines, mismo oi.tax), el frontend
//     devuelve totales y breakdown idénticos sin importar el `forcedOrigin`.
//   - Modifiers se incluyen en subtotal cuando aplican.
//   - Discounts se restan del total una sola vez.
//   - Items inclusive no doble-extraen impuesto.
//   - Items exentos (sin tax_lines) → breakdown vacío, sin "propina fantasma".
//
// Si estos tests fallan, hay regresión en el motor unificado y el deploy
// debe bloquearse hasta investigar.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/order_item_tax_line.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';

const _txItbis = 'tax-itbis';
const _txLey = 'tax-ley';

OrderItemTaxLine _line({
  required String itemId,
  required String taxId,
  required String taxName,
  required double rate,
  required double amount,
}) {
  return OrderItemTaxLine(
    id: 'line_${itemId}_$taxId',
    orderItemId: itemId,
    taxId: taxId,
    taxName: taxName,
    taxRate: rate,
    amount: amount,
    createdAt: DateTime(2026, 1, 1),
  );
}

OrderItem _item({
  required String id,
  required double subtotal,
  required double tax,
  double quantity = 1,
  double unitPrice = 50,
  double discounts = 0,
  bool isTakeout = false,
  String taxMode = 'exclusive',
  double taxRate = 28,
  double? originalTaxRate,
  String status = 'pending',
  List<OrderItemTaxLine> taxLines = const [],
  List<OrderItemModifier> modifiers = const [],
}) {
  return OrderItem(
    id: id,
    orderId: 'order-1',
    productId: 'prod-$id',
    productName: 'Item $id',
    quantity: quantity,
    unitPrice: unitPrice,
    subtotal: subtotal,
    discounts: discounts,
    tax: tax,
    total: subtotal + tax - discounts,
    isTakeout: isTakeout,
    status: status,
    taxMode: taxMode,
    taxRate: taxRate,
    originalTaxRate: originalTaxRate ?? taxRate,
    createdAt: DateTime(2026, 1, 1),
    taxLines: taxLines,
    modifiers: modifiers,
  );
}

Order _order({
  double subtotal = 0,
  double tax = 0,
  double serviceFee = 0,
  double discounts = 0,
  String origin = 'dine_in',
}) {
  return Order(
    id: 'order-1',
    sessionId: 'session-1',
    status: 'open',
    subtotal: subtotal,
    tax: tax,
    serviceFee: serviceFee,
    discounts: discounts,
    total: subtotal + tax + serviceFee - discounts,
    origin: origin,
    createdAt: DateTime(2026, 1, 1),
  );
}

/// Crea un Agua Dasany (50, exclusive) con ITBIS 18% + Ley 10% aplicados
/// según el modelo unificado de PRD 2.5: oi.tax_rate=28, oi.tax=14,
/// oi.tax_lines = [ITBIS 9, Ley 5].
OrderItem _aguaDasany() {
  return _item(
    id: 'agua',
    subtotal: 50,
    tax: 14,
    unitPrice: 50,
    taxMode: 'exclusive',
    taxRate: 28,
    taxLines: [
      _line(itemId: 'agua', taxId: _txItbis, taxName: 'ITBIS', rate: 18, amount: 9),
      _line(itemId: 'agua', taxId: _txLey, taxName: '10% De Ley', rate: 10, amount: 5),
    ],
  );
}

void main() {
  group('PRD 2.5 — Cross-origin parity', () {
    // ─────────────────────────────────────────────────────────────────
    // P1: mismo item produce totales idénticos en los 4 origins.
    // ─────────────────────────────────────────────────────────────────
    test('P1: Agua Dasany (50, ITBIS+Ley) — totales idénticos en zone/manual/quick/delivery', () {
      final item = _aguaDasany();
      final order = _order(subtotal: 50, tax: 14);

      final zone = summarizeOrderPricing(order, [item], forcedOrigin: 'zone');
      final manual = summarizeOrderPricing(order, [item], forcedOrigin: 'manual');
      final quick = summarizeOrderPricing(order, [item], forcedOrigin: 'quick');
      final delivery = summarizeOrderPricing(order, [item], forcedOrigin: 'delivery');

      // Subtotal idéntico
      expect(zone.subtotal, manual.subtotal);
      expect(zone.subtotal, quick.subtotal);
      expect(zone.subtotal, delivery.subtotal);
      expect(zone.subtotal, 50.0);

      // Tax idéntico (incluye Ley consolidada)
      expect(zone.tax, manual.tax);
      expect(zone.tax, quick.tax);
      expect(zone.tax, delivery.tax);
      expect(zone.tax, 14.0);

      // Total idéntico
      expect(zone.total, manual.total);
      expect(zone.total, quick.total);
      expect(zone.total, delivery.total);
      expect(zone.total, 64.0);
    });

    // ─────────────────────────────────────────────────────────────────
    // P2: breakdown de tax_lines idéntico en todos los origins.
    // ─────────────────────────────────────────────────────────────────
    test('P2: breakdown desde tax_lines es idéntico en los 4 origins', () {
      final item = _aguaDasany();
      final order = _order(subtotal: 50, tax: 14);

      final zone = buildOrderTaxBreakdown(order, [item], forcedOrigin: 'zone');
      final manual = buildOrderTaxBreakdown(order, [item], forcedOrigin: 'manual');
      final quick = buildOrderTaxBreakdown(order, [item], forcedOrigin: 'quick');
      final delivery = buildOrderTaxBreakdown(order, [item], forcedOrigin: 'delivery');

      for (final breakdown in [zone, manual, quick, delivery]) {
        expect(breakdown.length, 2, reason: 'esperaba 2 líneas (ITBIS + Ley)');
        expect(breakdown[0].label, '10% De Ley (10%)');
        expect(breakdown[0].amount, 5.0);
        expect(breakdown[1].label, 'ITBIS (18%)');
        expect(breakdown[1].amount, 9.0);
      }
    });

    // ─────────────────────────────────────────────────────────────────
    // P3: Producto con modifier — subtotal incluye modifier en todos los origins.
    // ─────────────────────────────────────────────────────────────────
    test('P3: MARGARITAS (450 + chinola 600 modifier) — totales y breakdown idénticos cross-origin', () {
      final modifier = OrderItemModifier(
        id: 'mod-chinola',
        itemId: 'margaritas',
        name: 'chinola',
        qty: 1,
        price: 600,
      );
      final item = _item(
        id: 'margaritas',
        subtotal: 1050, // backend ya consolidó: 450 base + 600 modifier
        tax: 294, // 1050 × 28%
        quantity: 1,
        unitPrice: 450,
        taxMode: 'exclusive',
        taxRate: 28,
        modifiers: [modifier],
        taxLines: [
          _line(itemId: 'margaritas', taxId: _txItbis, taxName: 'ITBIS', rate: 18, amount: 189),
          _line(itemId: 'margaritas', taxId: _txLey, taxName: '10% De Ley', rate: 10, amount: 105),
        ],
      );
      final order = _order(subtotal: 1050, tax: 294);

      for (final origin in ['zone', 'manual', 'quick', 'delivery']) {
        final summary = summarizeOrderPricing(order, [item], forcedOrigin: origin);
        expect(summary.subtotal, 1050.0, reason: 'subtotal en $origin');
        expect(summary.tax, 294.0, reason: 'tax en $origin');
        expect(summary.total, 1344.0, reason: 'total en $origin');
      }
    });

    // ─────────────────────────────────────────────────────────────────
    // P4: takeout no excluye Ley (eso fue regla histórica que PRD 2.5 elimina).
    //     Lo que filtre takeout es responsabilidad del backend al
    //     poblar tax_lines (no del frontend).
    // ─────────────────────────────────────────────────────────────────
    test('P4: items takeout — frontend trust tax_lines del backend', () {
      // Si backend decide NO aplicar Ley en takeout, NO la pone en tax_lines.
      // El frontend solo refleja lo que recibe.
      final item = _item(
        id: 'agua-takeout',
        subtotal: 50,
        tax: 9, // solo ITBIS, sin Ley
        unitPrice: 50,
        isTakeout: true,
        taxMode: 'exclusive',
        taxRate: 18,
        taxLines: [
          _line(itemId: 'agua-takeout', taxId: _txItbis, taxName: 'ITBIS', rate: 18, amount: 9),
        ],
      );
      final order = _order(subtotal: 50, tax: 9);

      for (final origin in ['zone', 'manual', 'quick', 'delivery']) {
        final summary = summarizeOrderPricing(order, [item], forcedOrigin: origin);
        expect(summary.tax, 9.0, reason: 'takeout en $origin: solo ITBIS');
        expect(summary.total, 59.0, reason: 'takeout en $origin');

        final breakdown = buildOrderTaxBreakdown(order, [item], forcedOrigin: origin);
        expect(breakdown.length, 1, reason: 'takeout en $origin: solo 1 línea');
        expect(breakdown[0].label, 'ITBIS (18%)');
      }
    });

    // ─────────────────────────────────────────────────────────────────
    // P5: items legítimamente exentos (sin tax_lines, sin tax) →
    //     breakdown vacío. NO inventar propina fantasma.
    // ─────────────────────────────────────────────────────────────────
    test('P5: item exento en cualquier origin → breakdown vacío, sin propina fantasma', () {
      final item = _item(
        id: 'exento',
        subtotal: 100,
        tax: 0,
        taxRate: 0,
        taxLines: [],
      );
      final order = _order(subtotal: 100);

      for (final origin in ['zone', 'manual', 'quick', 'delivery']) {
        final summary = summarizeOrderPricing(order, [item], forcedOrigin: origin);
        expect(summary.tax, 0.0, reason: 'exento en $origin');
        expect(summary.serviceFee, 0.0, reason: 'sin propina fantasma en $origin');
        expect(summary.total, 100.0);

        final breakdown = buildOrderTaxBreakdown(order, [item], forcedOrigin: origin);
        expect(breakdown.length, 0, reason: 'exento en $origin: sin líneas');
      }
    });

    // ─────────────────────────────────────────────────────────────────
    // P6: discount — se resta una sola vez del total, idéntico cross-origin.
    // ─────────────────────────────────────────────────────────────────
    test('P6: discount aplicado idénticamente en los 4 origins', () {
      final item = _item(
        id: 'agua-disc',
        subtotal: 50,
        tax: 14,
        discounts: 10,
        taxRate: 28,
        taxLines: [
          _line(itemId: 'agua-disc', taxId: _txItbis, taxName: 'ITBIS', rate: 18, amount: 9),
          _line(itemId: 'agua-disc', taxId: _txLey, taxName: '10% De Ley', rate: 10, amount: 5),
        ],
      );
      final order = _order(subtotal: 50, tax: 14, discounts: 10);

      for (final origin in ['zone', 'manual', 'quick', 'delivery']) {
        final summary = summarizeOrderPricing(order, [item], forcedOrigin: origin);
        expect(summary.discounts, 10.0, reason: 'discount en $origin');
        // Total = subtotal + tax - discounts = 50 + 14 - 10 = 54
        expect(summary.total, 54.0, reason: 'total con discount en $origin');
      }
    });

    // ─────────────────────────────────────────────────────────────────
    // P7: inclusive — base extraída es estable cross-origin.
    // ─────────────────────────────────────────────────────────────────
    test('P7: item inclusive — backend ya extrajo subtotal con tasa consolidada', () {
      // Producto inclusive de RD$ 100 con ITBIS 18 + Ley 10 = 28%.
      // Backend extrajo: subtotal = 100/1.28 = 78.13, tax = 21.87.
      final item = _item(
        id: 'incl',
        subtotal: 78.13,
        tax: 21.87,
        unitPrice: 100,
        taxMode: 'inclusive',
        taxRate: 28,
        taxLines: [
          _line(itemId: 'incl', taxId: _txItbis, taxName: 'ITBIS', rate: 18, amount: 14.06),
          _line(itemId: 'incl', taxId: _txLey, taxName: '10% De Ley', rate: 10, amount: 7.81),
        ],
      );
      final order = _order(subtotal: 78.13, tax: 21.87);

      for (final origin in ['zone', 'manual', 'quick', 'delivery']) {
        final summary = summarizeOrderPricing(order, [item], forcedOrigin: origin);
        expect(summary.subtotal, closeTo(78.13, 0.01), reason: 'inclusive subtotal en $origin');
        expect(summary.tax, closeTo(21.87, 0.01), reason: 'inclusive tax en $origin');
        expect(summary.total, closeTo(100.0, 0.01), reason: 'inclusive total en $origin');
      }
    });

    // ─────────────────────────────────────────────────────────────────
    // P8: orden multi-item — la suma cross-origin es idéntica.
    // ─────────────────────────────────────────────────────────────────
    test('P8: 2 items distintos — totales idénticos en los 4 origins', () {
      final agua = _aguaDasany();
      final coca = _item(
        id: 'coca',
        subtotal: 50,
        tax: 14,
        unitPrice: 50,
        taxMode: 'exclusive',
        taxRate: 28,
        taxLines: [
          _line(itemId: 'coca', taxId: _txItbis, taxName: 'ITBIS', rate: 18, amount: 9),
          _line(itemId: 'coca', taxId: _txLey, taxName: '10% De Ley', rate: 10, amount: 5),
        ],
      );
      final order = _order(subtotal: 100, tax: 28);

      for (final origin in ['zone', 'manual', 'quick', 'delivery']) {
        final summary = summarizeOrderPricing(order, [agua, coca], forcedOrigin: origin);
        expect(summary.subtotal, 100.0, reason: 'multi-item en $origin');
        expect(summary.tax, 28.0, reason: 'multi-item en $origin');
        expect(summary.total, 128.0, reason: 'multi-item en $origin');

        final breakdown = buildOrderTaxBreakdown(order, [agua, coca], forcedOrigin: origin);
        expect(breakdown.length, 2, reason: 'breakdown multi-item en $origin');
        // ITBIS agrupado: 9 + 9 = 18
        // Ley agrupada: 5 + 5 = 10
        final itbisLine = breakdown.firstWhere((b) => b.label == 'ITBIS (18%)');
        final leyLine = breakdown.firstWhere((b) => b.label == '10% De Ley (10%)');
        expect(itbisLine.amount, 18.0);
        expect(leyLine.amount, 10.0);
      }
    });

    // ─────────────────────────────────────────────────────────────────
    // P9: items void se ignoran en breakdown y totales.
    // ─────────────────────────────────────────────────────────────────
    test('P9: items void no contribuyen al subtotal/tax/breakdown en ningún origin', () {
      final agua = _aguaDasany();
      final voided = _item(
        id: 'voided',
        subtotal: 100,
        tax: 28,
        status: 'void',
        taxLines: [
          _line(itemId: 'voided', taxId: _txItbis, taxName: 'ITBIS', rate: 18, amount: 18),
          _line(itemId: 'voided', taxId: _txLey, taxName: '10% De Ley', rate: 10, amount: 10),
        ],
      );
      final order = _order(subtotal: 50, tax: 14);

      for (final origin in ['zone', 'manual', 'quick', 'delivery']) {
        final summary = summarizeOrderPricing(order, [agua, voided], forcedOrigin: origin);
        expect(summary.subtotal, 50.0, reason: 'void ignorado en $origin');
        expect(summary.tax, 14.0, reason: 'void ignorado en $origin');
        expect(summary.total, 64.0);
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // Sanity: confirma que `forcedOrigin` ya no afecta el cálculo del frontend.
  // (La filtración por origin se hace 100% en el backend al poblar tax_lines.)
  // ───────────────────────────────────────────────────────────────────────
  group('PRD 2.5 — forcedOrigin no debe alterar resultados frontend', () {
    test('summarizeItemPricing es estable contra forcedOrigin con mismo input', () {
      final item = _aguaDasany();
      final order = _order(subtotal: 50, tax: 14);

      final results = [
        for (final origin in [null, 'zone', 'manual', 'quick', 'delivery', 'unknown'])
          summarizeItemPricing(order, item, forcedOrigin: origin),
      ];

      // Todos los resultados deben tener el mismo subtotal/tax/total.
      final subtotals = results.map((r) => r.subtotal).toSet();
      final taxes = results.map((r) => r.tax).toSet();
      final totals = results.map((r) => r.total).toSet();

      expect(subtotals.length, 1, reason: 'subtotal cambia con forcedOrigin');
      expect(taxes.length, 1, reason: 'tax cambia con forcedOrigin');
      expect(totals.length, 1, reason: 'total cambia con forcedOrigin');
    });
  });
}
