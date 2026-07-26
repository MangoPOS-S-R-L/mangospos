import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/purchases/utils/discount_input.dart';

void main() {
  group('DiscountInput.parse', () {
    test('vacío o ilegible es cero', () {
      expect(DiscountInput.parse('').isZero, isTrue);
      expect(DiscountInput.parse('   ').isZero, isTrue);
      expect(DiscountInput.parse('abc').isZero, isTrue);
      expect(DiscountInput.parse('%').isZero, isTrue);
      expect(DiscountInput.parse('0').isZero, isTrue);
    });

    test('número simple es monto', () {
      final d = DiscountInput.parse('150');
      expect(d.isPercent, isFalse);
      expect(d.value, 150);
    });

    test('sufijo % es porcentaje', () {
      final d = DiscountInput.parse('10%');
      expect(d.isPercent, isTrue);
      expect(d.value, 10);
    });

    test('acepta decimales y espacios', () {
      expect(DiscountInput.parse(' 12.5% ').value, 12.5);
      expect(DiscountInput.parse('99.99').value, 99.99);
    });
  });

  group('DiscountInput.amountOn', () {
    test('monto se aplica directo', () {
      expect(DiscountInput.parse('150').amountOn(1000), 150);
    });

    test('porcentaje se aplica sobre la base', () {
      expect(DiscountInput.parse('10%').amountOn(1000), 100);
    });

    test('monto mayor que la base se clampa (no deja base negativa)', () {
      expect(DiscountInput.parse('5000').amountOn(1000), 1000);
    });

    test('porcentaje mayor a 100 se clampa a la base', () {
      expect(DiscountInput.parse('150%').amountOn(1000), 1000);
    });

    test('base cero o negativa no descuenta', () {
      expect(DiscountInput.parse('10%').amountOn(0), 0);
      expect(DiscountInput.parse('100').amountOn(-5), 0);
    });
  });
}
