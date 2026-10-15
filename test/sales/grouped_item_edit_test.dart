import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_order_projector.dart';
import 'package:mangopos/core/offline/hub/hub_kitchen_projector.dart';
import 'package:mangopos/core/offline/order_item_snapshot.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/utils/grouped_item_edit.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';

OrderItem row(
  String id, {
  double qty = 4,
  double discount = 250,
  String check = 'c1',
}) => OrderItem.fromMap({
  'id': id,
  'order_id': 'order',
  'product_id': 'beer',
  'product_name': '4x3 Presidente',
  'qty': qty,
  'unit_price': 250,
  'subtotal': qty * 250 / 1.28,
  'tax': qty * 250 - qty * 250 / 1.28,
  'discounts': discount,
  'tax_mode': 'inclusive',
  'tax_rate': 28,
  'total': qty * 250 - discount,
  'status': 'pending',
  'check_id': check,
  'notes': '[DEAL:promo]\n[DEAL_RULE:4:250.00]',
  'version': 1,
  'created_at': '2026-10-14T12:00:00Z',
});
void main() {
  for (final (qty, total, count) in [
    (12.0, 2250.0, 3),
    (8.0, 1500.0, 2),
    (7.0, 1500.0, 2),
    (6.0, 1250.0, 2),
    (4.0, 750.0, 1),
  ]) {
    test('grupo de 8 a $qty conserva paquetes completos y rondas', () {
      final rows = [row('a'), row('b')];
      final plan = planGroupedItemEdit(
        rows: rows,
        edited: rows.first.copyWith(quantity: qty, discounts: 500),
        newId: () => 'new',
      );
      expect(plan.items.length, count);
      expect(plan.items.fold<double>(0, (s, i) => s + i.quantity), qty);
      expect(summarizeOrderPricing(null, plan.items).total, total);
      if (qty > 8) {
        expect(
          plan.items.where((i) => i.status == 'pending').map((i) => i.quantity),
          [4, 4],
        );
        expect(plan.items.singleWhere((i) => i.status == 'draft').quantity, 4);
        expect(plan.items.map((i) => i.discounts), [250, 250, 250]);
      }
    });
  }
  test('aumentar una oferta de 4 a 8 reparte 250 por ronda', () {
    final source = row('a');
    final plan = planGroupedItemEdit(
      rows: [source],
      edited: source.copyWith(quantity: 8, discounts: 500),
      newId: () => 'new',
    );
    expect(plan.items.map((i) => i.discounts), [250, 250]);
    expect(plan.items.map((i) => i.quantity), [4, 4]);
  });
  test('aumentar una ronda de 3 a 4 da una oferta y solo envía la nueva', () {
    final source = row('a', qty: 3, discount: 0);
    final plan = planGroupedItemEdit(
      rows: [source],
      edited: source.copyWith(quantity: 4, discounts: 250),
      newId: () => 'new',
    );
    expect(plan.items.map((i) => i.quantity), [3, 1]);
    expect(plan.items.map((i) => i.discounts), [0, 250]);
    expect(summarizeOrderPricing(null, plan.items).total, 750);
  });
  test('cortesía explícita sigue cubriendo las rondas retenidas y nuevas', () {
    final source = row('a');
    final plan = planGroupedItemEdit(
      rows: [source],
      edited: source.copyWith(
        quantity: 8,
        discounts: 2000,
        notes: '[DEAL:promo]\n[DEAL_RULE:4:250.00]\n[CORTESIA:autorizada]',
      ),
      newId: () => 'new',
    );
    expect(plan.items.map((i) => i.discounts), [1000, 1000]);
    expect(summarizeOrderPricing(null, plan.items).total, 0);
    expect((plan.actions.last['args'] as Map)['discounts'], 1000);
  });
  test('no combina ofertas entre subcuentas', () {
    final result = repriceOfferGroups([
      row('a', qty: 3, discount: 0),
      row('b', qty: 1, discount: 250, check: 'c2'),
    ]);
    expect(result.fold<double>(0, (s, i) => s + i.discounts), 0);
    expect(summarizeOrderPricing(null, result).total, 1000);
  });
  test('eliminar todas las unidades produce un solo lote de borrados', () {
    final rows = [row('a'), row('b')];
    final plan = planGroupedItemEdit(
      rows: rows,
      edited: rows.first.copyWith(quantity: 0),
      newId: () => 'new',
    );
    expect(plan.items, isEmpty);
    expect(plan.removedIds, ['a', 'b']);
    expect(plan.actions.every((a) => a['kind'] == 'delete'), isTrue);
  });
  test(
    'Hub aplica el grupo completo y KDS espera el envío de la nueva ronda',
    () {
      final rows = [row('a'), row('b')];
      final plan = planGroupedItemEdit(
        rows: rows,
        edited: rows.first.copyWith(quantity: 12),
        newId: () => 'new',
      );
      final ops = <Map<String, dynamic>>[
        for (var i = 0; i < rows.length; i++)
          {
            'seq': i + 1,
            'type': 'add_item',
            'order_id': 'order',
            'table_id': 't1',
            'item_id': rows[i].id,
            'product_name': rows[i].productName,
            'qty': 4,
            'product_price': 250,
            'notes': rows[i].notes,
            'item_snapshot': OrderItemSnapshot.encode(rows[i]),
          },
        {'seq': 3, 'type': 'send_to_kitchen', 'order_id': 'order'},
        {
          'seq': 4,
          'type': 'edit_item_group',
          'order_id': 'order',
          'table_id': 't1',
          'actions': plan.actions,
          'result_items': plan.items.map(OrderItemSnapshot.encode).toList(),
          'removed_ids': plan.removedIds,
        },
      ];
      final projected = HubOrderProjector.projectOrder(ops, orderId: 'order')!;
      expect(projected.total, 2250);
      expect(projected.items.length, 3);
      expect(HubKitchenProjector.project(ops).single.items.map((i) => i.id), [
        'a',
        'b',
      ]);
      ops.add({'seq': 5, 'type': 'send_to_kitchen', 'order_id': 'order'});
      expect(HubKitchenProjector.project(ops).single.items.map((i) => i.id), [
        'a',
        'b',
        'new',
      ]);
    },
  );
}
