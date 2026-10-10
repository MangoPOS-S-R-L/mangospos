import 'package:flutter_test/flutter_test.dart';

import 'package:mangopos/data/repositories/order_review_repository.dart';

/// Pedido del dueño (10-oct): la cuenta en revisión debe llegar con el nombre
/// del mesero y el número de la mesa (`fn_review_accounts`, 20261010_0024).
void main() {
  Map<String, dynamic> row({Object? waiter, Object? table}) => {
    'id': 'o-1',
    'review_reason': 'offline_conflict',
    'review_at': '2026-10-10T19:19:00Z',
    'waiter_name': waiter,
    'table_code': table,
    'order_items': [
      {
        'product_name': 'PLATO',
        'quantity': 1,
        'qty': 1,
        'total': 250,
        'status': 'pending',
      },
      {
        'product_name': 'ANULADO',
        'quantity': 1,
        'qty': 1,
        'total': 99,
        'status': 'void',
      },
    ],
  };

  test('lee quién la tomó y en qué mesa', () {
    final a = ReviewAccount.fromRow(row(waiter: 'Claudia', table: 'MESA71'));
    expect(a.waiterName, 'Claudia');
    expect(a.tableCode, 'MESA71');
    expect(a.items.map((i) => i.name), ['PLATO']);
    expect(a.total, 250);
  });

  test('sin la migración (sin esos campos) no rompe', () {
    final a = ReviewAccount.fromRow(row());
    expect(a.waiterName, isNull);
    expect(a.tableCode, isNull);
  });

  test('textos vacíos cuentan como ausentes', () {
    final a = ReviewAccount.fromRow(row(waiter: '  ', table: ''));
    expect(a.waiterName, isNull);
    expect(a.tableCode, isNull);
  });
}
