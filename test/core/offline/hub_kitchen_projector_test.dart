import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_kitchen_projector.dart';

/// Tests del proyector de cocina (F3c): dobla el op-log en KitchenOrders.
void main() {
  Map<String, dynamic> op(int seq, String type, Map<String, dynamic> extra) =>
      {'seq': seq, 'type': type, ...extra};

  test('items NO aparecen hasta que la orden se envía a cocina', () {
    final orders = HubKitchenProjector.project([
      op(1, 'add_item', {
        'order_id': 'o1',
        'item_id': 'tmp_a',
        'product_name': 'Pizza',
        'qty': 2,
      }),
    ]);
    expect(orders, isEmpty); // sin send_to_kitchen, no visible
  });

  test('send_to_kitchen hace visibles los items como pending', () {
    final orders = HubKitchenProjector.project([
      op(1, 'add_item', {
        'order_id': 'o1',
        'item_id': 'tmp_a',
        'product_name': 'Pizza',
        'qty': 2,
        'notes': 'sin cebolla',
      }),
      op(2, 'add_item', {
        'order_id': 'o1',
        'item_id': 'tmp_b',
        'product_name': 'Agua',
        'qty': 1,
      }),
      op(3, 'send_to_kitchen', {'order_id': 'o1'}),
    ]);
    expect(orders.length, 1);
    final o = orders.single;
    expect(o.items.length, 2);
    expect(o.items.every((i) => i.isPending), isTrue);
    final pizza = o.items.firstWhere((i) => i.productName == 'Pizza');
    expect(pizza.quantity, 2);
    expect(pizza.notes, 'sin cebolla');
  });

  test('delete_item y update_item_quantity se reflejan', () {
    final orders = HubKitchenProjector.project([
      op(1, 'add_item',
          {'order_id': 'o1', 'item_id': 'tmp_a', 'product_name': 'Pizza', 'qty': 1}),
      op(2, 'add_item',
          {'order_id': 'o1', 'item_id': 'tmp_b', 'product_name': 'Agua', 'qty': 1}),
      op(3, 'update_item_quantity', {'order_id': 'o1', 'item_id': 'tmp_a', 'quantity': 5}),
      op(4, 'delete_item', {'order_id': 'o1', 'item_id': 'tmp_b'}),
      op(5, 'send_to_kitchen', {'order_id': 'o1'}),
    ]);
    final o = orders.single;
    expect(o.items.length, 1);
    expect(o.items.single.productName, 'Pizza');
    expect(o.items.single.quantity, 5);
  });

  test('kds_item_status mueve a preparing/ready y served lo quita', () {
    final base = [
      op(1, 'add_item',
          {'order_id': 'o1', 'item_id': 'tmp_a', 'product_name': 'Pizza', 'qty': 1}),
      op(2, 'add_item',
          {'order_id': 'o1', 'item_id': 'tmp_b', 'product_name': 'Agua', 'qty': 1}),
      op(3, 'send_to_kitchen', {'order_id': 'o1'}),
    ];
    final preparing = HubKitchenProjector.project([
      ...base,
      op(4, 'kds_item_status', {'order_id': 'o1', 'item_id': 'tmp_a', 'status': 'preparing'}),
    ]);
    expect(
      preparing.single.items.firstWhere((i) => i.id == 'tmp_a').isPreparing,
      isTrue,
    );

    final served = HubKitchenProjector.project([
      ...base,
      op(4, 'kds_item_status', {'order_id': 'o1', 'item_id': 'tmp_a', 'status': 'served'}),
    ]);
    // tmp_a servido sale del KDS; queda solo Agua.
    expect(served.single.items.length, 1);
    expect(served.single.items.single.id, 'tmp_b');
  });

  test('void_order quita toda la orden', () {
    final orders = HubKitchenProjector.project([
      op(1, 'add_item',
          {'order_id': 'o1', 'item_id': 'tmp_a', 'product_name': 'Pizza', 'qty': 1}),
      op(2, 'send_to_kitchen', {'order_id': 'o1'}),
      op(3, 'void_order', {'order_id': 'o1'}),
    ]);
    expect(orders, isEmpty);
  });

  test('procesa en orden seq aunque lleguen desordenadas', () {
    final orders = HubKitchenProjector.project([
      op(3, 'send_to_kitchen', {'order_id': 'o1'}),
      op(1, 'add_item',
          {'order_id': 'o1', 'item_id': 'tmp_a', 'product_name': 'Pizza', 'qty': 1}),
      op(2, 'update_item_quantity', {'order_id': 'o1', 'item_id': 'tmp_a', 'quantity': 3}),
    ]);
    expect(orders.single.items.single.quantity, 3);
  });

  test('dos órdenes distintas se agrupan por separado', () {
    final orders = HubKitchenProjector.project([
      op(1, 'add_item',
          {'order_id': 'o1', 'item_id': 'tmp_a', 'product_name': 'Pizza', 'qty': 1}),
      op(2, 'send_to_kitchen', {'order_id': 'o1'}),
      op(3, 'add_item',
          {'order_id': 'o2', 'item_id': 'tmp_b', 'product_name': 'Taco', 'qty': 1}),
      op(4, 'send_to_kitchen', {'order_id': 'o2'}),
    ]);
    expect(orders.length, 2);
  });
}
