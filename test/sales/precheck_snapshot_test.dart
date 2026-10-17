import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/logic/payment_fresh_total.dart';
import 'package:mangopos/presentation/sales/logic/precheck_snapshot.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';

final _createdAt = DateTime(2026, 10, 16);

Order _order({String id = 'order-1', double deliveryFee = 0}) => Order(
  id: id,
  sessionId: 'session-1',
  status: 'open',
  subtotal: 1770,
  discounts: 0,
  serviceFee: 0,
  tax: 0,
  total: 1770,
  deliveryFee: deliveryFee,
  createdAt: _createdAt,
);

OrderItem _item({
  String id = 'initial',
  String? checkId,
  double price = 1770,
  String status = 'ready',
  List<OrderItemModifier> modifiers = const [],
}) => OrderItem(
  id: id,
  orderId: 'order-1',
  productName: id,
  quantity: 1,
  unitPrice: price,
  subtotal: price,
  discounts: 0,
  tax: 0,
  total: price,
  checkId: checkId,
  isTakeout: false,
  status: status,
  taxMode: 'inclusive',
  createdAt: _createdAt,
  modifiers: modifiers,
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

CurrentOrderState _state({
  Order? order,
  List<OrderItem>? items,
  List<OrderCheck> checks = const [],
  String? checkId,
}) => CurrentOrderState(
  order: order ?? _order(),
  items: items ?? [_item()],
  checks: checks,
  selectedCheckId: checkId,
  origin: 'table',
);

PrecheckSnapshot _capture(CurrentOrderState state, {String? checkId}) =>
    PrecheckSnapshot.capture(
      state,
      expectedOrderId: 'order-1',
      checkId: checkId,
    )!;

void main() {
  test('blocks a late 425 addition while print metadata is pending', () async {
    var live = _state();
    final snapshot = _capture(live);
    final metadata = Completer<void>();
    final dispatched = <double>[];

    final printWhenPrepared = () async {
      await metadata.future;
      if (snapshot.matches(live)) dispatched.add(snapshot.summary.total);
    }();
    live = live.copyWith(
      items: [
        ...live.items,
        _item(id: 'added', price: 425),
      ],
    );
    metadata.complete();
    await printWhenPrepared;

    expect(snapshot.summary.total, 1770);
    expect(_capture(live).summary.total, 2195);
    expect(dispatched, isEmpty);
  });

  test('allows an unchanged account after the metadata wait', () async {
    final live = _state();
    final snapshot = _capture(live);
    final metadata = Completer<void>();
    final ready = metadata.future.then((_) => snapshot.matches(live));
    metadata.complete();
    expect(await ready, isTrue);
  });

  test(
    'same total with a different product invalidates the printed content',
    () {
      final snapshot = _capture(_state());
      final changed = _state(items: [_item(id: 'replacement')]);
      expect(_capture(changed).summary.total, snapshot.summary.total);
      expect(snapshot.matches(changed), isFalse);
    },
  );

  test(
    'detects price and modifier changes, including modifiers with no cost',
    () {
      final snapshot = _capture(_state());
      expect(snapshot.matches(_state(items: [_item(price: 2195)])), isFalse);
      expect(
        snapshot.matches(
          _state(
            items: [
              _item(
                modifiers: const [
                  OrderItemModifier(
                    id: 'm1',
                    itemId: 'initial',
                    name: 'Selección',
                    qty: 1,
                    price: 0,
                  ),
                ],
              ),
            ],
          ),
        ),
        isFalse,
      );
    },
  );

  test('rejects navigation to another order or selected subaccount', () {
    final snapshot = _capture(_state());
    expect(snapshot.matches(_state(order: _order(id: 'another'))), isFalse);
    expect(snapshot.matches(_state(checkId: 'c1')), isFalse);
    expect(snapshot.matches(_state().copyWith(origin: 'delivery')), isFalse);
  });

  test('subaccount excludes other products and the order delivery fee', () {
    final live = _state(
      order: _order(deliveryFee: 100),
      items: [
        _item(checkId: 'c1'),
        _item(id: 'other', checkId: 'c2', price: 425),
      ],
      checks: [_check('c1'), _check('c2')],
      checkId: 'c1',
    );
    final snapshot = _capture(live, checkId: 'c1');
    expect(snapshot.items.map((item) => item.id), ['initial']);
    expect(snapshot.order.deliveryFee, 0);
    expect(snapshot.summary.total, 1770);
    expect(snapshot.matches(live.copyWith(selectedCheckId: 'c2')), isFalse);
    expect(
      snapshot.matches(live.copyWith(checks: [_check('c1', closed: true)])),
      isFalse,
    );
  });

  test('ignores ordering and kitchen progress without financial changes', () {
    final first = _item(status: 'preparing');
    final second = _item(id: 'second', price: 425);
    final snapshot = _capture(_state(items: [first, second]));
    final live = _state(
      items: [
        second,
        first.copyWith(status: 'ready', version: 2),
      ],
    );
    expect(snapshot.matches(live), isTrue);
    expect(
      snapshot.matches(
        _state(
          items: [
            second,
            first.copyWith(status: 'paid'),
          ],
        ),
      ),
      isFalse,
    );
  });

  test(
    'snapshot lists cannot be changed by later mutations of source lists',
    () {
      final modifiers = <OrderItemModifier>[];
      final items = [_item(modifiers: modifiers)];
      final snapshot = _capture(_state(items: items));
      modifiers.add(
        const OrderItemModifier(
          id: 'm1',
          itemId: 'initial',
          name: 'Extra',
          qty: 1,
          price: 425,
        ),
      );
      items.add(_item(id: 'later', price: 425));
      expect(snapshot.items, hasLength(1));
      expect(snapshot.items.single.modifiers, isEmpty);
      expect(() => snapshot.items.add(_item()), throwsUnsupportedError);
    },
  );

  test(
    'a consumption added after printing is included in the fresh payment',
    () {
      final printedState = _state();
      final printed = _capture(printedState);
      expect(printed.matches(printedState), isTrue);

      final later = printedState.copyWith(
        items: [
          ...printedState.items,
          _item(id: 'later', price: 425),
        ],
      );
      final paymentTotal = freshPaymentScopeTotal(
        expectedOrderId: 'order-1',
        order: later.order,
        items: later.items,
        checks: later.checks,
        forcedOrigin: later.origin,
      );
      expect(printed.summary.total, 1770);
      expect(paymentTotal, 2195);
    },
  );
}
