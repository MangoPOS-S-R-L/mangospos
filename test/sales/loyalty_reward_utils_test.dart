import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/utils/loyalty_reward_utils.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';

const _rid = '0f8b7c1e-2d3a-4b5c-8d9e-0a1b2c3d4e5f';
const _c1 = 'c0000000-0000-0000-0000-000000000001';
const _c2 = 'c0000000-0000-0000-0000-000000000002';
const _esp = 'd0000000-0000-0000-0000-000000000001';
const _lat = 'd0000000-0000-0000-0000-000000000002';
const _agua = 'd0000000-0000-0000-0000-000000000004';

LoyaltyRewardLine _line(
  String id, {
  String? productId = _esp,
  double qty = 1,
  double unitGross = 100,
  double discounts = 0,
  String status = 'served',
  String? customerId = _c1,
  String? notes,
}) {
  final gross = qty * unitGross;
  return LoyaltyRewardLine(
    id: id,
    productId: productId,
    productName: 'x',
    quantity: qty,
    subtotal: double.parse((gross / 1.18).toStringAsFixed(2)),
    tax: double.parse((gross - gross / 1.18).toStringAsFixed(2)),
    discounts: discounts,
    status: status,
    customerId: customerId,
    notes: notes,
  );
}

String _uuid(int n) =>
    'a0000000-0000-0000-0000-${n.toString().padLeft(12, '0')}';

void main() {
  group('marcador', () {
    test('lee unidades y quita solo la línea del premio', () {
      const notes = 'poco hielo\n[LOYALTY:$_rid:2]';
      expect(hasLoyaltyReward(notes), isTrue);
      expect(loyaltyRewardUnits(notes), 2);
      expect(stripLoyaltyMarkers(notes), 'poco hielo');
      expect(loyaltyMarkerLine(notes), '[LOYALTY:$_rid:2]');
    });

    test('marcador sin unidades vale 1; sin marcador vale 0', () {
      expect(loyaltyRewardUnits('[LOYALTY:$_rid]'), 1);
      expect(loyaltyRewardUnits('sin azúcar'), 0);
      expect(loyaltyRewardUnits(null), 0);
      expect(stripLoyaltyMarkers('[LOYALTY:$_rid:1]'), '');
    });

    test('el ticket y la cocina no ven el marcador; ven «Premio de fidelidad»',
        () {
      expect(
        cleanOrderItemNote('poco hielo\n[LOYALTY:$_rid:1]'),
        'poco hielo · Premio de fidelidad',
      );
      expect(cleanOrderItemNote('[LOYALTY:$_rid:1]'), 'Premio de fidelidad');
    });
  });

  group('monto del premio', () {
    test('1 gratis de 2 espressos de 100 = 100', () {
      final amount = loyaltyRewardAmount(
        subtotal: 169.49,
        tax: 30.51,
        quantity: 2,
        notes: '[LOYALTY:$_rid:1]',
      );
      expect(amount, 100.0);
    });

    test('nunca más que la línea', () {
      final amount = loyaltyRewardAmount(
        subtotal: 84.75,
        tax: 15.25,
        quantity: 1,
        notes: '[LOYALTY:$_rid:3]',
      );
      expect(amount, 100.0);
    });

    test('10 % encima de una línea con premio: el premio se queda', () {
      // 3 lattes de 150 (450), 1 gratis (150): el 10 % va sobre los 300
      // que sí paga → 150 + 30 = 180.
      final discount = discountKeepingLoyaltyReward(
        subtotal: 381.36,
        tax: 68.64,
        quantity: 3,
        notes: '[LOYALTY:$_rid:1]',
        manualOnRest: (rest) => rest * 0.10,
      );
      expect(discount, closeTo(180.0, 0.001));
    });

    test('sin premio el descuento manual queda exactamente igual que antes',
        () {
      final discount = discountKeepingLoyaltyReward(
        subtotal: 381.36,
        tax: 68.64,
        quantity: 3,
        notes: 'sin azúcar',
        manualOnRest: (rest) => rest * 0.10,
      );
      expect(discount, closeTo(45.0, 0.001));
      expect(
        loyaltyDiscountableBase(
          subtotal: 381.36,
          tax: 68.64,
          quantity: 3,
          notes: null,
        ),
        closeTo(450.0, 0.001),
      );
    });

    test('monto fijo encima nunca pasa de lo que el cliente paga', () {
      final discount = discountKeepingLoyaltyReward(
        subtotal: 84.75,
        tax: 15.25,
        quantity: 1,
        notes: '[LOYALTY:$_rid:1]',
        manualOnRest: (rest) => 50,
      );
      expect(discount, 100.0);
    });
  });

  group('líneas que pueden recibir el premio', () {
    test('la más barata primero; orden estable por id', () {
      final result = loyaltyRewardCandidates(
        lines: [
          _line(_uuid(3), productId: _lat, unitGross: 150),
          _line(_uuid(2), unitGross: 100),
          _line(_uuid(1), unitGross: 100),
        ],
        eligibleProductIds: {_esp, _lat},
        customerId: _c1,
      );
      expect(result.map((l) => l.id), [_uuid(1), _uuid(2), _uuid(3)]);
    });

    test('precio por UNIDAD, no por fila', () {
      final result = loyaltyRewardCandidates(
        lines: [
          _line(_uuid(1), qty: 3, unitGross: 100), // fila 300, unidad 100
          _line(_uuid(2), productId: _lat, unitGross: 150),
        ],
        eligibleProductIds: {_esp, _lat},
        customerId: _c1,
      );
      expect(result.first.id, _uuid(1));
    });

    test('excluye lo que el servidor rechazaría', () {
      final result = loyaltyRewardCandidates(
        lines: [
          _line(_uuid(1), status: 'paid'),
          _line(_uuid(2), status: 'void'),
          _line('local-item-1'),
          _line(_uuid(3), customerId: _c2),
          _line(_uuid(4), productId: _agua),
          _line(_uuid(5), discounts: 10),
          _line(_uuid(6), notes: '[PROMO_AUTO:abc]'),
          _line(_uuid(7), notes: '[CORTESIA:gerente]'),
          _line(_uuid(8), notes: '[LOYALTY:$_rid:1]'),
          _line(_uuid(9), qty: 0.5),
          _line(_uuid(10), unitGross: 0),
          _line(_uuid(11), productId: null),
          _line(_uuid(12), notes: 'sin azúcar'),
        ],
        eligibleProductIds: {_esp},
        customerId: _c1,
      );
      expect(result.map((l) => l.id), [_uuid(12)]);
    });
  });
}
