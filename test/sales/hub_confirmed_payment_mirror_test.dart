import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_order_projector.dart';
import 'package:mangopos/core/offline/hub/hub_payment_mirror.dart';

void main() {
  final opened = <Map<String, dynamic>>[
    {
      'seq': 1,
      'type': 'open_table',
      'order_id': 'order-1',
      'table_id': 'table-1',
    },
    {
      'seq': 2,
      'type': 'add_item',
      'order_id': 'order-1',
      'item_id': 'item-1',
      'qty': 1,
      'product_price': 640,
    },
  ];

  test('pago total confirmado retira la tarjeta antigua del Hub', () {
    final payment = confirmedPaymentHubOp(
      orderId: 'order-1',
      paymentId: 'payment-1',
    );
    expect(payment['hub_applied'], isTrue);
    expect(payment['op_id'], 'confirmed-payment-payment-1');
    expect(HubOrderProjector.projectSalon(opened), hasLength(1));
    expect(
      HubOrderProjector.projectSalon([
        ...opened,
        {...payment, 'seq': 3},
      ]),
      isEmpty,
    );
  });

  test('pago de una subcuenta no cierra las otras', () {
    final payment = confirmedPaymentHubOp(
      orderId: 'order-1',
      paymentId: 'payment-2',
      checkId: 'check-2',
    );
    expect(payment['close_order'], isFalse);
    expect(payment['close_check'], isTrue);
    expect(
      HubOrderProjector.projectSalon([
        ...opened,
        {...payment, 'seq': 3},
      ]),
      hasLength(1),
    );
  });
}
