// Qué líneas pierden unidades al quitar «N de M» de un producto agrupado.
//
// El caso que lo originó: un cajero con PIN de supervisor quería quitar 1 de
// «6 × Presidente» y la app borraba las 6 líneas — y si era lo único de la
// mesa, la cuenta entera.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/logic/unit_removal_plan.dart';

OrderItem _line(String id, double qty, {String? checkId}) => OrderItem(
  id: id,
  orderId: 'order-1',
  productId: 'presidente',
  productName: 'Presidente',
  quantity: qty,
  unitPrice: 200,
  subtotal: 200 * qty,
  discounts: 0,
  tax: 0,
  total: 200 * qty,
  isTakeout: false,
  status: 'pending',
  checkId: checkId,
  createdAt: DateTime(2026, 10, 5),
);

String _name(String? checkId) => switch (checkId) {
  'c1' => 'C1',
  'c2' => 'C2',
  _ => 'Sin subcuenta',
};

void main() {
  group('planUnitRemoval', () {
    test('quitar 1 de 6 toca UNA línea, no las seis', () {
      // Tres rondas de 2, como las agrupa el carrito (la más nueva primero).
      final rows = [_line('r3', 2), _line('r2', 2), _line('r1', 2)];
      final plan = planUnitRemoval(rows, 1);

      expect(plan, hasLength(1));
      expect(plan.single.item.id, 'r1');
      expect(plan.single.nextQuantity, 1);
      expect(plan.single.deletesRow, isFalse);
      expect(plan.single.removedQuantity, 1);
    });

    test('recorta desde la última línea, igual que el «−» del modal', () {
      final rows = [_line('r3', 2), _line('r2', 2), _line('r1', 2)];
      final plan = planUnitRemoval(rows, 3);

      // r1 se va entera y a r2 le queda 1; r3 no se toca.
      expect(plan.map((s) => s.item.id), ['r2', 'r1']);
      expect(plan.firstWhere((s) => s.item.id == 'r1').deletesRow, isTrue);
      expect(plan.firstWhere((s) => s.item.id == 'r2').nextQuantity, 1);
    });

    test('una sola línea de 6: quitar 1 la deja en 5', () {
      final plan = planUnitRemoval([_line('r1', 6)], 1);
      expect(plan.single.nextQuantity, 5);
      expect(plan.single.deletesRow, isFalse);
    });

    test('quitar todas borra todas las líneas', () {
      final rows = [_line('r2', 2), _line('r1', 4)];
      final plan = planUnitRemoval(rows, 6);
      expect(plan, hasLength(2));
      expect(plan.every((s) => s.deletesRow), isTrue);
      expect(plan.fold<double>(0, (sum, s) => sum + s.removedQuantity), 6);
    });
  });

  group('canRemoveByUnits', () {
    test('más de una unidad entera: se escoge cuántas', () {
      expect(canRemoveByUnits([_line('a', 2)]), isTrue);
      expect(canRemoveByUnits([_line('a', 1), _line('b', 1)]), isTrue);
    });

    test('una sola unidad o peso fraccionado: no hay qué escoger', () {
      expect(canRemoveByUnits([_line('a', 1)]), isFalse);
      expect(canRemoveByUnits([_line('a', 1.5), _line('b', 1)]), isFalse);
    });
  });

  group('describeRemovalAcrossChecks', () {
    test('todo en una subcuenta: no hay nada que avisar', () {
      final rows = [_line('a', 2, checkId: 'c1'), _line('b', 2, checkId: 'c1')];
      expect(describeRemovalAcrossChecks(rows, 1, checkName: _name), isNull);
    });

    test('en varias subcuentas dice de cuál sale', () {
      final rows = [_line('a', 2, checkId: 'c1'), _line('b', 2, checkId: 'c2')];
      expect(
        describeRemovalAcrossChecks(rows, 1, checkName: _name),
        'Este producto está en varias subcuentas. Se quita de C2: 1.',
      );
      expect(
        describeRemovalAcrossChecks(rows, 4, checkName: _name),
        'Este producto está en varias subcuentas. Se quita de C1: 2 · C2: 2.',
      );
    });
  });
}
