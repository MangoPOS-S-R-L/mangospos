import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/logic/payment_fresh_total.dart';

Order _order({
  String id = 'order-1',
  double total = 6900,
  double deliveryFee = 0,
  String status = 'open',
}) => Order(
  id: id,
  sessionId: 'session-1',
  status: status,
  subtotal: 0,
  discounts: 0,
  serviceFee: 0,
  tax: 0,
  total: total,
  deliveryFee: deliveryFee,
  createdAt: DateTime(2026, 10, 16),
);

OrderItem _item({
  String id = 'item-1',
  String orderId = 'order-1',
  String? checkId,
  double price = 6800,
  double discount = 0,
  String status = 'ready',
}) => OrderItem(
  id: id,
  orderId: orderId,
  productName: id,
  quantity: 1,
  unitPrice: price,
  subtotal: price,
  discounts: discount,
  tax: 0,
  total: price - discount,
  checkId: checkId,
  isTakeout: false,
  status: status,
  taxMode: 'inclusive',
  createdAt: DateTime(2026, 10, 16),
);

OrderCheck _check(String id, {bool closed = false}) => OrderCheck(
  id: id,
  orderId: 'order-1',
  label: id,
  position: 1,
  isClosed: closed,
  subtotal: 0,
  discounts: 0,
  serviceFee: 0,
  tax: 0,
  total: 0,
);

double? _total({
  Order? order,
  required List<OrderItem> items,
  List<OrderCheck> checks = const [],
  String? checkId,
}) => freshPaymentScopeTotal(
  expectedOrderId: 'order-1',
  order: order ?? _order(),
  items: items,
  checks: checks,
  checkId: checkId,
);

void main() {
  test('reduces a stale 6900 total to the fresh 6800 item total', () {
    expect(_total(items: [_item()]), 6800);
  });

  test('also includes products added since the button was built', () {
    expect(
      _total(
        order: _order(total: 6800),
        items: [
          _item(),
          _item(id: 'added', price: 100),
        ],
      ),
      6900,
    );
  });

  test('refreshes only the selected open subaccount', () {
    expect(
      _total(
        items: [
          _item(checkId: 'c1', price: 500),
          _item(id: 'other', checkId: 'c2', price: 900),
          _item(id: 'unassigned', price: 100),
        ],
        checks: [_check('c1'), _check('c2')],
        checkId: 'c1',
      ),
      500,
    );
  });

  test('pending order excludes paid, void and closed-subaccount products', () {
    expect(
      _total(
        items: [
          _item(price: 100),
          _item(id: 'paid', price: 200, status: 'paid'),
          _item(id: 'void', price: 300, status: 'void'),
          _item(id: 'closed', checkId: 'c1', price: 400),
          _item(id: 'open', checkId: 'c2', price: 500),
        ],
        checks: [_check('c1', closed: true), _check('c2')],
      ),
      600,
    );
  });

  test('includes fresh discounts and the exempt delivery fee', () {
    expect(
      _total(
        order: _order(deliveryFee: 50),
        items: [_item(price: 500, discount: 100)],
      ),
      450,
    );
  });

  test('does not duplicate the order delivery fee in a subaccount', () {
    expect(
      _total(
        order: _order(deliveryFee: 50),
        items: [_item(checkId: 'c1', price: 500)],
        checks: [_check('c1')],
        checkId: 'c1',
      ),
      500,
    );
  });

  test('allows a courtesy total of zero while products remain open', () {
    expect(_total(items: [_item(price: 500, discount: 500)]), 0);
  });

  test('rejects another order after navigation', () {
    expect(
      _total(
        order: _order(id: 'another-order'),
        items: [_item()],
      ),
      isNull,
    );
  });

  test('rejects a missing order', () {
    expect(
      freshPaymentScopeTotal(
        expectedOrderId: 'order-1',
        order: null,
        items: [_item()],
        checks: const [],
      ),
      isNull,
    );
  });

  test('rejects closed orders and scopes with no products left', () {
    expect(
      _total(
        order: _order(status: 'paid'),
        items: [_item()],
      ),
      isNull,
    );
    expect(_total(items: [_item(status: 'paid')]), isNull);
    expect(_total(items: [_item(orderId: 'another-order')]), isNull);
  });

  test('rejects a subaccount removed or closed during the refresh', () {
    expect(
      _total(
        items: [_item(checkId: 'c1')],
        checkId: 'c1',
      ),
      isNull,
    );
    expect(
      _total(
        items: [_item(checkId: 'c1')],
        checks: [_check('c1', closed: true)],
        checkId: 'c1',
      ),
      isNull,
    );
  });
}
