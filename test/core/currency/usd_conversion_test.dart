// PRD 6 §8.1 — Tests unitarios de calculateUsdEquivalent.
//
// 9 casos cubriendo:
//   - Conversiones normales (T1, T2, T3, T7, T9)
//   - Edge cases que retornan null (T4, T5, T6)
//   - Redondeo HALF_UP (T8)

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/currency/usd_conversion.dart';

void main() {
  Decimal d(String s) => Decimal.parse(s);

  group('calculateUsdEquivalent', () {
    test('T1: 5400.00 / 60.50 → 89.26', () {
      final result = calculateUsdEquivalent(
        dopTotal: d('5400.00'),
        usdRate: d('60.50'),
      );
      expect(result, equals(d('89.26')));
    });

    test('T2: 1000.00 / 60.00 → 16.67 (redondea desde 16.6666...)', () {
      final result = calculateUsdEquivalent(
        dopTotal: d('1000.00'),
        usdRate: d('60.00'),
      );
      expect(result, equals(d('16.67')));
    });

    test('T3: 0.00 / 60.50 → 0.00', () {
      final result = calculateUsdEquivalent(
        dopTotal: d('0.00'),
        usdRate: d('60.50'),
      );
      expect(result, equals(d('0.00')));
    });

    test('T4: rate = 0 → null', () {
      final result = calculateUsdEquivalent(
        dopTotal: d('5400.00'),
        usdRate: Decimal.zero,
      );
      expect(result, isNull);
    });

    test('T5: rate = null → null', () {
      final result = calculateUsdEquivalent(
        dopTotal: d('5400.00'),
        usdRate: null,
      );
      expect(result, isNull);
    });

    test('T6: rate negativa (-10) → null', () {
      final result = calculateUsdEquivalent(
        dopTotal: d('5400.00'),
        usdRate: d('-10'),
      );
      expect(result, isNull);
    });

    test('T7: 99999.99 / 60.5000 → 1652.89', () {
      final result = calculateUsdEquivalent(
        dopTotal: d('99999.99'),
        usdRate: d('60.5000'),
      );
      expect(result, equals(d('1652.89')));
    });

    test('T8: 1.50 / 60.5050 → 0.02 (HALF_UP)', () {
      // 1.50 / 60.5050 = 0.02479...
      // HALF_UP a 2 decimales = 0.02
      final result = calculateUsdEquivalent(
        dopTotal: d('1.50'),
        usdRate: d('60.5050'),
      );
      expect(result, equals(d('0.02')));
    });

    test('T9: 33.33 / 3.0000 → 11.11', () {
      final result = calculateUsdEquivalent(
        dopTotal: d('33.33'),
        usdRate: d('3.0000'),
      );
      expect(result, equals(d('11.11')));
    });
  });
}
