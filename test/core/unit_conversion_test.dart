import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/inventory/unit_conversion.dart';

void main() {
  group('unit_conversion — convertUnit', () {
    test('oz → ml usa 29.5735', () {
      expect(convertUnit(1, 'oz', 'ml'), closeTo(29.5735, 0.0001));
      expect(convertUnit(1.5, 'oz', 'ml'), closeTo(44.36, 0.01));
    });

    test('L → ml = 1000; cl → ml = 10', () {
      expect(convertUnit(1, 'L', 'ml'), 1000);
      expect(convertUnit(1, 'cl', 'ml'), 10);
    });

    test('kg → g = 1000; g → kg = 0.001', () {
      expect(convertUnit(1, 'kg', 'g'), 1000);
      expect(convertUnit(500, 'g', 'kg'), closeTo(0.5, 1e-9));
    });

    test('misma unidad no cambia', () {
      expect(convertUnit(45, 'ml', 'ml'), 45);
    });

    test('familias distintas → null', () {
      expect(convertUnit(1, 'oz', 'g'), isNull);
      expect(convertUnit(1, 'ml', 'kg'), isNull);
    });

    test('unidad desconocida (ej. botella) → null', () {
      expect(convertUnit(1, 'botella', 'ml'), isNull);
    });

    test('case-insensitive y con espacios', () {
      expect(convertUnit(1, ' OZ ', 'ML'), closeTo(29.5735, 0.0001));
    });
  });

  group('unit_conversion — familias y compatibilidad', () {
    test('unitFamily clasifica correctamente', () {
      expect(unitFamily('oz'), UnitFamily.volume);
      expect(unitFamily('ml'), UnitFamily.volume);
      expect(unitFamily('kg'), UnitFamily.weight);
      expect(unitFamily('unidad'), UnitFamily.count);
      expect(unitFamily('botella'), UnitFamily.unknown);
    });

    test('areConvertible solo dentro de la misma familia conocida', () {
      expect(areConvertible('oz', 'ml'), isTrue);
      expect(areConvertible('kg', 'g'), isTrue);
      expect(areConvertible('oz', 'g'), isFalse);
      expect(areConvertible('botella', 'ml'), isFalse);
    });
  });
}
