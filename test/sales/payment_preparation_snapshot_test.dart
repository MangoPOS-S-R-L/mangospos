import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/logic/precheck_snapshot.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';

final _createdAt = DateTime(2026, 10, 16);

OrderItem _item(String id, double price, {String? checkId}) => OrderItem(
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
  status: 'ready',
  taxMode: 'inclusive',
  createdAt: _createdAt,
);

OrderCheck _check(String id) => OrderCheck(
  id: id,
  orderId: 'order-1',
  label: id,
  position: 1,
  isClosed: false,
  subtotal: 0,
  discounts: 0,
  serviceFee: 0,
  tax: 0,
  total: 0,
);

CurrentOrderState _state(List<OrderItem> items, {String? selectedCheckId}) =>
    CurrentOrderState(
      order: Order(
        id: 'order-1',
        sessionId: 'session-1',
        status: 'open',
        subtotal: 2195,
        discounts: 0,
        serviceFee: 0,
        tax: 0,
        total: 2195,
        createdAt: _createdAt,
      ),
      items: items,
      checks: [_check('c1'), _check('c2')],
      selectedCheckId: selectedCheckId,
      origin: 'table',
    );

void main() {
  test(
    'rejects a same-price replacement while confirming payment total',
    () async {
      var live = _state([_item('consumption', 1770), _item('gin', 425)]);
      final snapshot = PrecheckSnapshot.capture(
        live,
        expectedOrderId: 'order-1',
        checkId: null,
      )!;
      final coverageConfirmation = Completer<void>();
      final chargedSnapshots = <PrecheckSnapshot>[];
      final preparePayment = () async {
        await coverageConfirmation.future;
        if (snapshot.matches(live)) chargedSnapshots.add(snapshot);
      }();

      live = live.copyWith(
        items: [_item('consumption', 1770), _item('vodka', 425)],
      );
      coverageConfirmation.complete();
      await preparePayment;

      final updated = PrecheckSnapshot.capture(
        live,
        expectedOrderId: 'order-1',
        checkId: null,
      )!;
      expect(updated.summary.total, snapshot.summary.total);
      expect(chargedSnapshots, isEmpty);
    },
  );

  test('full payment includes all checks even when one is selected in UI', () {
    final live = _state([
      _item('first-check', 1000, checkId: 'c1'),
      _item('second-check', 770, checkId: 'c2'),
      _item('unassigned', 425),
    ], selectedCheckId: 'c1');
    // The payment button defines its scope independently of the selected tab.
    final paymentScope = live.copyWith(clearSelectedCheck: true);
    final snapshot = PrecheckSnapshot.capture(
      paymentScope,
      expectedOrderId: 'order-1',
      checkId: null,
    )!;

    expect(snapshot.summary.total, 2195);
    expect(snapshot.items, hasLength(3));
    expect(snapshot.matches(live.copyWith(clearSelectedCheck: true)), isTrue);
  });

  test('subaccount payment tracks its product even if total is unchanged', () {
    final live = _state([
      _item('first-check', 1770, checkId: 'c1'),
      _item('second-check', 425, checkId: 'c2'),
    ], selectedCheckId: 'c1');
    final snapshot = PrecheckSnapshot.capture(
      live,
      expectedOrderId: 'order-1',
      checkId: 'c1',
    )!;
    final changed = live.copyWith(
      items: [
        _item('replacement', 1770, checkId: 'c1'),
        _item('second-check', 425, checkId: 'c2'),
      ],
    );

    expect(snapshot.summary.total, 1770);
    expect(snapshot.matches(changed), isFalse);
  });
}
