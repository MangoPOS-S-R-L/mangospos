// El motivo de una merma se clasifica igual en la app (filtro de Salidas) que
// en el servidor (Rendimiento, 20260930_0050). Si divergen, los dos cuentan
// distinto.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/state/outflow_reasons.dart';

InventoryMovementEntry _m({
  String type = 'waste',
  double qty = -1,
  String? reason,
  String ref = 'manual_outflow',
  String notes = '',
}) => InventoryMovementEntry.fromMap(
  {
    'id': 'm',
    'item_id': 'i',
    'warehouse_id': 'w',
    'movement_type': type,
    'quantity': qty,
    'notes': notes,
    'reference_type': ref,
    'reason_code': reason,
    'created_at': '2026-09-30T12:00:00Z',
  },
  itemName: 'Leche',
  warehouseName: 'Principal',
);

void main() {
  test('el motivo guardado manda', () {
    expect(
      _m(reason: 'expiration', notes: 'Rotura / dañado').outflowReason,
      'expiration',
    );
  });

  test('producto quitado de la cuenta', () {
    expect(
      _m(ref: 'order_item_removal', notes: 'Merma: devuelto').outflowReason,
      kOrderRemovalReason,
    );
  });

  test('merma vieja: motivo en el prefijo de la nota', () {
    expect(_m(notes: 'Faltante / robo — bodega').outflowReason, 'theft');
    expect(_m(notes: 'Limpieza').outflowReason, 'cleaning');
  });

  test('sin nada reconocible: sin motivo', () {
    expect(_m(notes: 'se cayó').outflowReason, kUnspecifiedReason);
    expect(_m(reason: 'physical_count').outflowReason, kUnspecifiedReason);
  });

  test('qué cuenta como salida registrada', () {
    expect(_m().isRegisteredOutflow, isTrue);
    expect(
      _m(type: 'adjustment', reason: 'breakage').isRegisteredOutflow,
      isTrue,
    );
    // Un conteo o una corrección NO es merma.
    expect(
      _m(type: 'adjustment', reason: 'physical_count').isRegisteredOutflow,
      isFalse,
    );
    expect(_m(type: 'adjustment', reason: null).isRegisteredOutflow, isFalse);
    // Un ajuste que SUMA nunca es salida.
    expect(
      _m(type: 'adjustment', qty: 2, reason: 'breakage').isRegisteredOutflow,
      isFalse,
    );
  });

  test(
    'todos los motivos tienen etiqueta; uno desconocido cae en «Sin motivo»',
    () {
      for (final r in kOutflowReasons) {
        expect(outflowReasonByCode(r.code).label, isNotEmpty);
      }
      expect(outflowReasonByCode('lo-que-sea').code, kUnspecifiedReason);
    },
  );
}
