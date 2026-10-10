import 'package:flutter_test/flutter_test.dart';

import 'package:mangopos/data/models/table_status.dart';
import 'package:mangopos/data/models/zone.dart';
import 'package:mangopos/presentation/sales/widgets/review_accounts_sheet.dart';

/// «Mover a otra mesa» (20261010_0024): el selector usa las mesas que el salón
/// ya cargó, en el orden de sus zonas, sin la mesa de la cuenta.
void main() {
  TableStatus table(
    String id,
    String zone,
    String code, {
    String? sessionId,
    int ordersCount = 0,
    double total = 0,
  }) => TableStatus(
    tableId: id,
    zoneId: zone,
    code: code,
    sessionId: sessionId,
    ordersCount: ordersCount,
    minutesOpen: null,
    total: total,
  );

  final zones = [
    Zone(id: 'patio', name: 'PATIO', sortIndex: 2),
    Zone(id: 'salon', name: 'SALON', sortIndex: 1),
  ];
  final statusByZone = {
    'salon': [
      table(
        't-71',
        'salon',
        'MESA71',
        sessionId: 's',
        ordersCount: 2,
        total: 640,
      ),
      table('t-72', 'salon', 'MESA72'),
    ],
    'patio': [
      table('t-p1', 'patio', 'P1', sessionId: 's2', ordersCount: 1, total: 300),
    ],
  };

  test('sin la mesa de la cuenta, en el orden de las zonas', () {
    final targets = reviewMoveTargets(
      zones: zones,
      statusByZone: statusByZone,
      excludeTableId: 't-71',
    );
    expect(targets.map((t) => t.code), ['MESA72', 'P1']);
    expect(targets.map((t) => t.zoneName), ['SALON', 'PATIO']);
  });

  test('libre u ocupada con el mismo criterio que la tarjeta', () {
    final targets = reviewMoveTargets(
      zones: zones,
      statusByZone: statusByZone,
      excludeTableId: 't-71',
    );
    final mesa72 = targets.firstWhere((t) => t.code == 'MESA72');
    final p1 = targets.firstWhere((t) => t.code == 'P1');
    expect(mesa72.occupied, isFalse);
    expect(p1.occupied, isTrue);
    expect(p1.total, 300);
  });

  test('una zona sin estado cargado no rompe', () {
    final targets = reviewMoveTargets(
      zones: [
        ...zones,
        Zone(id: 'terraza', name: 'Terraza', sortIndex: 3),
      ],
      statusByZone: statusByZone,
      excludeTableId: 't-71',
    );
    expect(targets, hasLength(2));
  });
}
