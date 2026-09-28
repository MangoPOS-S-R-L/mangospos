import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_order_projector.dart';

/// H3: el proyector de salón/órdenes dobla el op-log del Hub en (a) las mesas
/// ocupadas del salón y (b) el detalle de una orden. Es lo que hace visible
/// entre cajas la mesa que abrió el mesero.
Map<String, dynamic> _op(int seq, String type, Map<String, dynamic> extra) => {
  'seq': seq,
  'type': type,
  ...extra,
};

void main() {
  test('a partial split never releases the table or permits log pruning', () {
    final ops = [
      _op(1, 'add_item', {
        'order_id': 'o1',
        'table_id': 't1',
        'item_id': 'i1',
        'product_price': 100,
        'qty': 1,
      }),
      _op(2, 'process_payment', {
        'order_id': 'o1',
        'amount': 40,
        'close_order': false,
        'close_check': false,
        'split_sequence': 0,
      }),
    ];
    expect(HubOrderProjector.projectSalon(ops), hasLength(1));
    expect(HubOrderProjector.openOrderIds(ops), contains('o1'));
    ops.add(
      _op(3, 'process_payment', {
        'order_id': 'o1',
        'amount': 60,
        'close_order': true,
        'split_sequence': 1,
      }),
    );
    expect(HubOrderProjector.projectSalon(ops), isEmpty);
    expect(HubOrderProjector.openOrderIds(ops), isEmpty);
  });

  test(
    'check settlement removes only paid items and closes the last check',
    () {
      final ops = [
        for (var i = 1; i <= 2; i++)
          _op(i, 'add_item', {
            'order_id': 'o1',
            'table_id': 't1',
            'item_id': 'i$i',
            'check_pos': 'c$i',
            'product_price': 100,
            'qty': 1,
          }),
        _op(3, 'process_payment', {
          'order_id': 'o1',
          'check_id': 'c1',
          'close_order': false,
          'close_check': false,
        }),
      ];
      expect(HubOrderProjector.projectSalon(ops).single.total, 200);
      ops.add(
        _op(4, 'process_payment', {
          'order_id': 'o1',
          'check_id': 'c1',
          'close_order': false,
          'close_check': true,
        }),
      );
      expect(HubOrderProjector.projectSalon(ops).single.total, 100);
      ops.add(
        _op(5, 'process_payment', {
          'order_id': 'o1',
          'check_id': 'c2',
          'close_order': false,
          'close_check': true,
        }),
      );
      expect(HubOrderProjector.projectSalon(ops), isEmpty);
      expect(HubOrderProjector.openOrderIds(ops), isEmpty);
    },
  );

  group('projectSalon', () {
    test('mesa con 2 ítems → 1 mesa ocupada con total correcto', () {
      final ops = [
        _op(1, 'open_table', {'order_id': 'o1', 'table_id': 't1'}),
        _op(2, 'add_item', {
          'order_id': 'o1',
          'table_id': 't1',
          'item_id': 'i1',
          'product_name': 'Cerveza',
          'product_price': 150,
          'qty': 2,
        }),
        _op(3, 'add_item', {
          'order_id': 'o1',
          'item_id': 'i2',
          'product_name': 'Agua',
          'product_price': 50,
          'qty': 1,
        }),
      ];
      final salon = HubOrderProjector.projectSalon(ops);
      expect(salon.length, 1);
      expect(salon.first.tableId, 't1');
      expect(salon.first.orderId, 'o1');
      expect(salon.first.itemsCount, 2);
      expect(salon.first.total, 2 * 150 + 1 * 50); // 350
      expect(salon.first.sentToKitchen, false);
    });

    test(
      'add_item sin table_id (venta rápida/manual) NO aparece en el salón',
      () {
        final ops = [
          _op(1, 'add_item', {
            'order_id': 'oq',
            'item_id': 'i1',
            'product_name': 'X',
            'product_price': 100,
            'qty': 1,
          }),
        ];
        expect(HubOrderProjector.projectSalon(ops), isEmpty);
      },
    );

    test('delete_item reduce el conteo; si quedan 0 la mesa se libera', () {
      final ops = [
        _op(1, 'add_item', {
          'order_id': 'o1',
          'table_id': 't1',
          'item_id': 'i1',
          'product_price': 100,
          'qty': 1,
        }),
        _op(2, 'delete_item', {'order_id': 'o1', 'item_id': 'i1'}),
      ];
      expect(HubOrderProjector.projectSalon(ops), isEmpty);
    });

    test('void_order libera la mesa', () {
      final ops = [
        _op(1, 'add_item', {
          'order_id': 'o1',
          'table_id': 't1',
          'item_id': 'i1',
          'product_price': 100,
          'qty': 1,
        }),
        _op(2, 'void_order', {'order_id': 'o1'}),
      ];
      expect(HubOrderProjector.projectSalon(ops), isEmpty);
    });

    test('cobro full-order (sin check) cierra la mesa', () {
      final ops = [
        _op(1, 'add_item', {
          'order_id': 'o1',
          'table_id': 't1',
          'item_id': 'i1',
          'product_price': 100,
          'qty': 1,
        }),
        _op(2, 'process_payment', {'order_id': 'o1', 'amount': 100}),
      ];
      expect(HubOrderProjector.projectSalon(ops), isEmpty);
    });

    test('cobro por-subcuenta (con check_id) deja la mesa ocupada', () {
      final ops = [
        _op(1, 'add_item', {
          'order_id': 'o1',
          'table_id': 't1',
          'item_id': 'i1',
          'product_price': 100,
          'qty': 1,
        }),
        _op(2, 'process_payment', {
          'order_id': 'o1',
          'check_id': 'c1',
          'amount': 50,
        }),
      ];
      expect(HubOrderProjector.projectSalon(ops).length, 1);
    });

    test('send_to_kitchen marca la mesa como enviada', () {
      final ops = [
        _op(1, 'add_item', {
          'order_id': 'o1',
          'table_id': 't1',
          'item_id': 'i1',
          'product_price': 100,
          'qty': 1,
        }),
        _op(2, 'send_to_kitchen', {'order_id': 'o1'}),
      ];
      final salon = HubOrderProjector.projectSalon(ops);
      expect(salon.single.sentToKitchen, true);
    });

    test(
      'el orden de las ops se respeta por seq aunque lleguen desordenadas',
      () {
        final ops = [
          _op(3, 'delete_item', {'order_id': 'o1', 'item_id': 'i1'}),
          _op(1, 'add_item', {
            'order_id': 'o1',
            'table_id': 't1',
            'item_id': 'i1',
            'product_price': 100,
            'qty': 1,
          }),
          _op(2, 'add_item', {
            'order_id': 'o1',
            'item_id': 'i2',
            'product_price': 100,
            'qty': 1,
          }),
        ];
        // i1 se borra (seq 3 tras crear en 1); queda i2.
        final salon = HubOrderProjector.projectSalon(ops);
        expect(salon.single.itemsCount, 1);
      },
    );
  });

  group('projectOrder', () {
    final ops = [
      _op(1, 'open_table', {'order_id': 'o1', 'table_id': 't1'}),
      _op(2, 'add_item', {
        'order_id': 'o1',
        'item_id': 'i1',
        'product_name': 'Cerveza',
        'product_price': 150,
        'qty': 2,
      }),
      _op(3, 'update_item_quantity', {
        'order_id': 'o1',
        'item_id': 'i1',
        'quantity': 3,
      }),
    ];

    test('por tableId devuelve el detalle con la cantidad actualizada', () {
      final order = HubOrderProjector.projectOrder(ops, tableId: 't1');
      expect(order, isNotNull);
      expect(order!.orderId, 'o1');
      expect(order.tableId, 't1');
      expect(order.items.single.productName, 'Cerveza');
      expect(order.items.single.quantity, 3);
      expect(order.total, 3 * 150);
    });

    test('por orderId también funciona', () {
      final order = HubOrderProjector.projectOrder(ops, orderId: 'o1');
      expect(order?.items.single.quantity, 3);
    });

    test('orden anulada devuelve null', () {
      final voided = [
        ...ops,
        _op(4, 'void_order', {'order_id': 'o1'}),
      ];
      expect(HubOrderProjector.projectOrder(voided, tableId: 't1'), isNull);
    });

    test('mesa inexistente devuelve null', () {
      expect(HubOrderProjector.projectOrder(ops, tableId: 'tX'), isNull);
    });
  });

  // Fix #2: el uplink del Hub poda el op-log CONSERVANDO solo las mesas aún
  // abiertas (openOrderIds); el resto (cerradas/anuladas + ops sin order_id)
  // se descarta tras subir.
  group('openOrderIds (poda del uplink)', () {
    test('orden abierta con ítems → incluida', () {
      final ops = [
        _op(1, 'open_table', {'order_id': 'o1', 'table_id': 't1'}),
        _op(2, 'add_item', {
          'order_id': 'o1',
          'item_id': 'i1',
          'product_price': 100,
          'qty': 1,
        }),
      ];
      expect(HubOrderProjector.openOrderIds(ops), {'o1'});
    });

    test('orden pagada full-order (cerrada) → EXCLUIDA', () {
      final ops = [
        _op(1, 'add_item', {
          'order_id': 'o1',
          'table_id': 't1',
          'item_id': 'i1',
          'product_price': 100,
          'qty': 1,
        }),
        _op(2, 'process_payment', {'order_id': 'o1', 'amount': 100}),
      ];
      expect(HubOrderProjector.openOrderIds(ops), isEmpty);
    });

    test('orden anulada → EXCLUIDA', () {
      final ops = [
        _op(1, 'open_table', {'order_id': 'o1', 'table_id': 't1'}),
        _op(2, 'void_order', {'order_id': 'o1'}),
      ];
      expect(HubOrderProjector.openOrderIds(ops), isEmpty);
    });

    test('cobro por-subcuenta (mesa sigue abierta) → incluida', () {
      final ops = [
        _op(1, 'open_table', {'order_id': 'o1', 'table_id': 't1'}),
        _op(2, 'process_payment', {
          'order_id': 'o1',
          'check_id': 'c1',
          'amount': 50,
        }),
      ];
      expect(HubOrderProjector.openOrderIds(ops), {'o1'});
    });

    test('orden abierta SIN ítems (todos borrados) → sigue incluida '
        '(no huérfana futuros add_item)', () {
      final ops = [
        _op(1, 'open_table', {'order_id': 'o1', 'table_id': 't1'}),
        _op(2, 'add_item', {
          'order_id': 'o1',
          'item_id': 'i1',
          'product_price': 100,
          'qty': 1,
        }),
        _op(3, 'delete_item', {'order_id': 'o1', 'item_id': 'i1'}),
      ];
      // projectSalon la oculta (0 ítems) pero sus ops se conservan para que un
      // add_item posterior siga asociando la mesa.
      expect(HubOrderProjector.projectSalon(ops), isEmpty);
      expect(HubOrderProjector.openOrderIds(ops), {'o1'});
    });

    test('mezcla: una abierta + una cerrada → solo la abierta', () {
      final ops = [
        _op(1, 'open_table', {'order_id': 'o1', 'table_id': 't1'}),
        _op(2, 'add_item', {
          'order_id': 'o1',
          'item_id': 'i1',
          'product_price': 100,
          'qty': 1,
        }),
        _op(3, 'open_table', {'order_id': 'o2', 'table_id': 't2'}),
        _op(4, 'add_item', {
          'order_id': 'o2',
          'item_id': 'i2',
          'product_price': 100,
          'qty': 1,
        }),
        _op(5, 'process_payment', {'order_id': 'o2', 'amount': 100}),
      ];
      expect(HubOrderProjector.openOrderIds(ops), {'o1'});
    });
  });
}
