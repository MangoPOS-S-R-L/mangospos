import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/order_item_snapshot.dart';
import 'package:mangopos/core/offline/hub/hub_order_projector.dart';
import 'package:mangopos/data/models/order_item_tax_line.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';

void main() {
  final at = DateTime.utc(2026, 9, 29);
  final item = OrderItem(
    id: 'i',
    orderId: 'o',
    productId: 'p',
    productName: 'Cafe',
    quantity: 2,
    unitPrice: 100,
    subtotal: 220,
    discounts: 10,
    tax: 39.6,
    total: 249.6,
    createdAt: at,
    taxRate: 18,
    originalTaxRate: 18,
    taxMode: 'exclusive',
    checkId: 'check',
    status: 'pending',
    isTakeout: false,
    notes: 'Caliente',
    printAreaCode: 'bar',
    createdByEmployeeId: 'employee',
    createdByEmployeeName: 'Mesero',
    modifiers: const [
      OrderItemModifier(
        id: 'm',
        itemId: 'i',
        name: 'Leche',
        qty: 1,
        price: 10,
        modifierId: 'milk',
      ),
    ],
    taxLines: [
      OrderItemTaxLine(
        id: 't',
        orderItemId: 'i',
        taxId: 'itbis',
        taxName: 'ITBIS',
        taxRate: 18,
        amount: 39.6,
        createdAt: at,
      ),
    ],
  );

  Map<String, dynamic> add(String id) => {
    'seq': 1,
    'type': 'add_item',
    'order_id': 'o',
    'table_id': 'table',
    'item_id': id,
    'product_name': 'Cafe',
    'qty': 2,
    'unit_price': 100,
    'item_snapshot': OrderItemSnapshot.encode(item.copyWith(id: id)),
  };

  test('JSON round trip preserves pricing, modifiers, taxes and waiter', () {
    final encoded =
        jsonDecode(jsonEncode(OrderItemSnapshot.encode(item))) as Map;
    expect(OrderItemSnapshot.decode(Map<String, dynamic>.from(encoded)), item);
  });

  test('sales hydration preserves the Hub fiscal breakdown', () {
    final hub = HubOrderProjector.projectOrder([
      add('i'),
    ], orderId: 'o')!.toJson();
    final state = SalesViewModel.stateFromHubOrder(hub);
    expect(state.items.single, item);
    expect(state.order!.subtotal, 220);
    expect(state.order!.tax, 39.6);
    expect(state.order!.discounts, 10);
    expect(state.order!.total, 249.6);
  });

  test('older Hub responses still hydrate their base item amount', () {
    final state = SalesViewModel.stateFromHubOrder({
      'order_id': 'old',
      'total': 200,
      'items': [
        {'id': 'i', 'quantity': 2, 'unit_price': 100},
      ],
    });
    expect(state.items.single.subtotal, 200);
    expect(state.items.single.total, 200);
  });

  test('remapped parent identity also updates nested item references', () {
    final decoded = OrderItemSnapshot.decode({
      ...OrderItemSnapshot.encode(item),
      'id': 'remote-i',
    });
    expect(decoded.modifiers.single.itemId, 'remote-i');
    expect(decoded.taxLines.single.orderItemId, 'remote-i');
  });

  test('Hub totals include extras, taxes and discounts for each item', () {
    final ops = [
      add('i'),
      {...add('sibling'), 'seq': 2},
    ];
    final projected = HubOrderProjector.projectOrder(
      ops,
      orderId: 'o',
    )!.toJson();
    expect(projected['total'], closeTo(499.2, 0.001));
    expect(projected['subtotal'], 440);
    expect(projected['tax'], 79.2);
    expect(projected['discounts'], 20);
    final restored = OrderItemSnapshot.decode(
      Map<String, dynamic>.from((projected['items'] as List).first as Map),
    );
    expect(restored, item);
    expect(
      HubOrderProjector.projectSalon(ops).single.total,
      projected['total'],
    );
  });

  test('updated snapshot changes only its item and keeps tax lines', () {
    final updated = item.copyWith(
      quantity: 1,
      subtotal: 110,
      tax: 19.8,
      total: 119.8,
    );
    final result = HubOrderProjector.projectOrder([
      add('i'),
      {...add('sibling'), 'seq': 2},
      {
        'seq': 3,
        'type': 'update_item_quantity',
        'order_id': 'o',
        'item_id': 'i',
        'quantity': 1,
        'item_snapshot': OrderItemSnapshot.encode(updated),
      },
    ], orderId: 'o')!;
    expect(result.items.first.total, 119.8);
    expect(result.items.last.total, 249.6);
    expect(result.total, closeTo(369.4, 0.001));
  });

  test('legacy quantity commands do not erase captured extras or taxes', () {
    final result = HubOrderProjector.projectOrder([
      add('i'),
      {
        'seq': 2,
        'type': 'update_item_quantity',
        'order_id': 'o',
        'item_id': 'i',
        'quantity': 4,
      },
    ], orderId: 'o')!.items.single.toJson();
    expect(result['subtotal'], 440);
    expect(result['tax'], 79.2);
    expect((result['modifiers'] as List).single['name'], 'Leche');
    expect((result['tax_lines'] as List).single['amount'], 79.2);
  });
}
