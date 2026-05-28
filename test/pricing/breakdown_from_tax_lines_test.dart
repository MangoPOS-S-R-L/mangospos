// Golden tests del nuevo path de desglose desde `order_item_tax_lines`
// (PRD 2 §6.1, frontend F2.3c).
//
// Validan `buildBreakdownFromTaxLines(items)` y la integración con
// `buildOrderTaxBreakdown(order, items)` que ahora usa el snapshot
// inmutable de tax_lines en vez de heurísticas.
//
// Comportamiento esperado:
//   - Items con tax_lines → breakdown desde snapshots, agrupado por tax_id.
//   - Items sin tax_lines → fallback al path heurístico viejo.
//   - tax_id es la clave de agrupamiento (estable a renombres de impuestos).
//   - Items en status='void' se ignoran.
//   - Líneas con amount ≈ 0 se filtran.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/order_item_tax_line.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';

OrderItemTaxLine _line({
  required String orderItemId,
  required String taxId,
  required String taxName,
  required double taxRate,
  required double amount,
}) {
  return OrderItemTaxLine(
    id: 'lid_${orderItemId}_$taxId',
    orderItemId: orderItemId,
    taxId: taxId,
    taxName: taxName,
    taxRate: taxRate,
    amount: amount,
    createdAt: DateTime(2026, 1, 1),
  );
}

OrderItem _item({
  required String id,
  String status = 'pending',
  List<OrderItemTaxLine> taxLines = const [],
  double subtotal = 100,
  double tax = 18,
}) {
  return OrderItem(
    id: id,
    orderId: 'order-1',
    productId: 'prod-$id',
    productName: 'Item $id',
    quantity: 1,
    unitPrice: 100,
    subtotal: subtotal,
    discounts: 0,
    tax: tax,
    total: subtotal + tax,
    isTakeout: false,
    status: status,
    createdAt: DateTime(2026, 1, 1),
    taxLines: taxLines,
  );
}

void main() {
  group('PRD 2 — buildBreakdownFromTaxLines', () {
    // ─────────────────────────────────────────────────────────────────
    // C1: un item con ITBIS + Propina linkeados → 2 líneas separadas.
    // ─────────────────────────────────────────────────────────────────
    test('C1: dos taxes distintos en un item → 2 líneas', () {
      final items = [
        _item(
          id: 'i1',
          subtotal: 585.94,
          tax: 164.06,
          taxLines: [
            _line(
              orderItemId: 'i1',
              taxId: 'tx-itbis',
              taxName: 'ITBIS',
              taxRate: 18,
              amount: 105.47,
            ),
            _line(
              orderItemId: 'i1',
              taxId: 'tx-propina',
              taxName: 'Propina Ley',
              taxRate: 10,
              amount: 58.59,
            ),
          ],
        ),
      ];

      final result = buildBreakdownFromTaxLines(items);

      expect(result, isNotNull);
      expect(result!.length, 2);
      // Orden alfabético por tax_name
      expect(result[0].label, 'ITBIS (18%)');
      expect(result[0].amount, closeTo(105.47, 0.01));
      expect(result[1].label, 'Propina Ley (10%)');
      expect(result[1].amount, closeTo(58.59, 0.01));
    });

    // ─────────────────────────────────────────────────────────────────
    // C2: dos items con MISMOS taxes → agrupan por tax_id.
    // ─────────────────────────────────────────────────────────────────
    test('C2: dos items con ITBIS → ITBIS sumado', () {
      final items = [
        _item(
          id: 'i1',
          taxLines: [
            _line(
              orderItemId: 'i1',
              taxId: 'tx-itbis',
              taxName: 'ITBIS',
              taxRate: 18,
              amount: 105.47,
            ),
          ],
        ),
        _item(
          id: 'i2',
          taxLines: [
            _line(
              orderItemId: 'i2',
              taxId: 'tx-itbis',
              taxName: 'ITBIS',
              taxRate: 18,
              amount: 70.31,
            ),
          ],
        ),
      ];

      final result = buildBreakdownFromTaxLines(items);

      expect(result, isNotNull);
      expect(result!.length, 1);
      expect(result[0].label, 'ITBIS (18%)');
      expect(result[0].amount, closeTo(175.78, 0.01));
    });

    // ─────────────────────────────────────────────────────────────────
    // C3: items en status='void' se ignoran.
    // ─────────────────────────────────────────────────────────────────
    test('C3: item void se descarta', () {
      final items = [
        _item(
          id: 'i1',
          taxLines: [
            _line(
              orderItemId: 'i1',
              taxId: 'tx-itbis',
              taxName: 'ITBIS',
              taxRate: 18,
              amount: 105.47,
            ),
          ],
        ),
        _item(
          id: 'i2',
          status: 'void',
          taxLines: [
            _line(
              orderItemId: 'i2',
              taxId: 'tx-itbis',
              taxName: 'ITBIS',
              taxRate: 18,
              amount: 999.99, // este NO debería contar
            ),
          ],
        ),
      ];

      final result = buildBreakdownFromTaxLines(items);

      expect(result, isNotNull);
      expect(result!.length, 1);
      expect(result[0].amount, closeTo(105.47, 0.01));
    });

    // ─────────────────────────────────────────────────────────────────
    // C4: ningún item con tax_lines → devuelve null (signaling fallback).
    // ─────────────────────────────────────────────────────────────────
    test('C4: items sin tax_lines → null (caller hace fallback)', () {
      final items = [_item(id: 'i1'), _item(id: 'i2')];

      final result = buildBreakdownFromTaxLines(items);

      expect(result, isNull);
    });

    // ─────────────────────────────────────────────────────────────────
    // C5: agrupamiento por nombre normalizado y rate (para fusionar
    // items optimistas con items confirmados por backend).
    // ─────────────────────────────────────────────────────────────────
    test('C5: agrupa por nombre normalizado y rate', () {
      final items = [
        _item(
          id: 'i1',
          taxLines: [
            _line(
              orderItemId: 'i1',
              taxId: 'tmp_tax_ITBIS',
              taxName: 'ITBIS',
              taxRate: 18,
              amount: 50,
            ),
          ],
        ),
        _item(
          id: 'i2',
          taxLines: [
            _line(
              orderItemId: 'i2',
              taxId: 'real-uuid-itbis',
              taxName: 'itbis', // minúsculas se normalizan
              taxRate: 18,
              amount: 30,
            ),
          ],
        ),
      ];

      final result = buildBreakdownFromTaxLines(items);

      expect(result, isNotNull);
      expect(result!.length, 1, reason: 'mismo nombre y rate → 1 sola línea');
      expect(result[0].amount, closeTo(80, 0.01));
      expect(result[0].label, 'ITBIS (18%)');
    });

    // ─────────────────────────────────────────────────────────────────
    // C6: amount ≈ 0 se filtra del breakdown.
    // ─────────────────────────────────────────────────────────────────
    test('C6: línea con amount ≈ 0 se omite', () {
      final items = [
        _item(
          id: 'i1',
          taxLines: [
            _line(
              orderItemId: 'i1',
              taxId: 'tx-itbis',
              taxName: 'ITBIS',
              taxRate: 18,
              amount: 105.47,
            ),
            _line(
              orderItemId: 'i1',
              taxId: 'tx-zero',
              taxName: 'Cero',
              taxRate: 0,
              amount: 0.001, // por debajo del threshold
            ),
          ],
        ),
      ];

      final result = buildBreakdownFromTaxLines(items);

      expect(result, isNotNull);
      expect(result!.length, 1);
      expect(result[0].label, 'ITBIS (18%)');
    });

    // ─────────────────────────────────────────────────────────────────
    // C7: producto exento (sin taxLines) en una orden donde otros
    // items SÍ tienen → solo cuenta el que tiene.
    // ─────────────────────────────────────────────────────────────────
    test('C7: mezcla exento + tributado → solo el tributado cuenta', () {
      final items = [
        _item(id: 'agua', taxLines: const []),
        _item(
          id: 'gaseosa',
          taxLines: [
            _line(
              orderItemId: 'gaseosa',
              taxId: 'tx-itbis',
              taxName: 'ITBIS',
              taxRate: 18,
              amount: 18,
            ),
          ],
        ),
      ];

      final result = buildBreakdownFromTaxLines(items);

      expect(result, isNotNull);
      expect(result!.length, 1);
      expect(result[0].amount, closeTo(18, 0.01));
    });

    // ─────────────────────────────────────────────────────────────────
    // C9: producto exento (tax=0, sin taxLines) → lista vacía explícita,
    // NO null. Esto es el caso "Agua Dasany en venta rápida": el item
    // legítimamente no tributa nada, así que el desglose debe estar vacío
    // y NO caer al fallback heurístico que cobraría 10% por default.
    // ─────────────────────────────────────────────────────────────────
    test('C9: items legítimamente exentos → [] (NO fallback)', () {
      final items = [
        _item(
          id: 'agua',
          subtotal: 50,
          tax: 0, // exento
          taxLines: const [],
        ),
      ];

      final result = buildBreakdownFromTaxLines(items);

      expect(result, isNotNull,
          reason: 'No debe devolver null cuando los items son legítimamente exentos');
      expect(result, isEmpty,
          reason: 'No debe agregar líneas fantasma');
    });

    // ─────────────────────────────────────────────────────────────────
    // C10: dos items, ambos exentos → []
    // ─────────────────────────────────────────────────────────────────
    test('C10: orden 100% exenta → []', () {
      final items = [
        _item(id: 'i1', subtotal: 50, tax: 0, taxLines: const []),
        _item(id: 'i2', subtotal: 30, tax: 0, taxLines: const []),
      ];

      final result = buildBreakdownFromTaxLines(items);

      expect(result, isEmpty);
    });

    // ─────────────────────────────────────────────────────────────────
    // C11: caso de regresión exacto del bug "Agua Dasany en Venta Rápida".
    // Producto exento (sin menu_item_taxes, tax=0, sin tax_lines) en una
    // orden post-PRD-2 → buildOrderTaxBreakdown debe devolver [] (no
    // agregar línea fantasma de Propina Ley 10%).
    // ─────────────────────────────────────────────────────────────────
    test('C11: regresión Agua Dasany en venta rápida → [] en breakdown', () {
      final aguaDasany = _item(
        id: 'agua-dasany',
        subtotal: 50,
        tax: 0,
        taxLines: const [],
      );
      // Order con serviceFee=0 (motor unificado del backend post-PRD-2)
      final order = Order(
        id: 'order-1',
        sessionId: 'session-1',
        status: 'open',
        subtotal: 50,
        discounts: 0,
        serviceFee: 0,
        tax: 0,
        total: 50,
        createdAt: DateTime(2026, 4, 28),
      );

      final breakdown = buildOrderTaxBreakdown(order, [aguaDasany]);

      expect(breakdown, isEmpty,
          reason:
              'Producto exento NO debe generar línea Propina Ley fantasma. '
              'Pre-PRD-2 cobraba 10% por default.');
    });

    // ─────────────────────────────────────────────────────────────────
    // C8: tax_rate decimal (no entero) se muestra con decimales.
    // ─────────────────────────────────────────────────────────────────
    test('C8: tax_rate decimal en label', () {
      final items = [
        _item(
          id: 'i1',
          taxLines: [
            _line(
              orderItemId: 'i1',
              taxId: 'tx-itc',
              taxName: 'ITC',
              taxRate: 5.5,
              amount: 27.50,
            ),
          ],
        ),
      ];

      final result = buildBreakdownFromTaxLines(items);

      expect(result, isNotNull);
      expect(result!.length, 1);
      expect(result[0].label, 'ITC (5.5%)');
    });
  });
}
