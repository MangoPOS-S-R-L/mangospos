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
      // `oz → g` ya NO va acá: la onza es ambigua y se resuelve contra la
      // familia de su contraparte. Con `g` del otro lado significa peso, que
      // es lo que la cocina necesita para «10 oz de pechuga». Los casos de
      // onza contextual tienen sus propios tests más abajo.
      expect(convertUnit(1, 'ml', 'kg'), isNull);
      expect(convertUnit(1, 'L', 'g'), isNull);
      expect(convertUnit(1, 'unidad', 'ml'), isNull);
    });

    test('lb → g usa 453.59237, y g/kg ↔ lb cierran el círculo', () {
      expect(convertUnit(1, 'lb', 'g'), closeTo(453.59237, 1e-5));
      expect(convertUnit(1, 'lb', 'kg'), closeTo(0.45359237, 1e-9));
      expect(convertUnit(1, 'kg', 'lb'), closeTo(2.20462, 1e-5));
      expect(convertUnit(453.59237, 'g', 'lb'), closeTo(1, 1e-9));
    });

    test('los alias de libra pesan lo mismo', () {
      for (final u in ['lb', 'lbs', 'libra', 'libras', 'LIBRA', ' Lb ']) {
        expect(convertUnit(1, u, 'g'), closeTo(453.59237, 1e-5),
            reason: 'alias $u');
      }
    });

    test('la libra NO se mezcla con volumen', () {
      expect(convertUnit(1, 'lb', 'ml'), isNull);
      expect(convertUnit(1, 'lb', 'L'), isNull);
      expect(unitFamily('lb'), UnitFamily.weight);
    });

    test('LA ONZA SE RESUELVE POR CONTEXTO — el caso de la pechuga', () {
      // Contra un insumo de PESO la onza pesa 28.3495 g. Sin esto, una receta
      // de «10 oz de pechuga» sobre un insumo en libras no convertía y
      // `_toBaseQty` guardaba 10 crudo: el plato descontaba 10 LIBRAS en vez
      // de 0.625. Dieciséis veces de más, en silencio.
      expect(convertUnit(1, 'oz', 'g'), closeTo(28.349523125, 1e-9));
      expect(convertUnit(10, 'oz', 'lb'), closeTo(0.625, 1e-9));
      expect(convertUnit(16, 'oz', 'lb'), closeTo(1, 1e-9));
      expect(convertUnit(8, 'oz', 'lb'), closeTo(0.5, 1e-9));
    });

    test('...y contra un líquido sigue siendo la onza del bar', () {
      // Los cócteles se escriben en oz y no se pueden mover.
      expect(convertUnit(1, 'oz', 'ml'), closeTo(29.5735, 1e-4));
      expect(convertUnit(1.5, 'oz', 'ml'), closeTo(44.36, 0.01));
      expect(convertUnit(1, 'oz', 'L'), closeTo(0.0295735, 1e-7));
    });

    test('la onza sola, sin contraparte, sigue siendo líquida', () {
      // Uso histórico: es lo que ya había y lo que espera el bar.
      expect(unitFamily('oz'), UnitFamily.volume);
      expect(unitFamily('onzas'), UnitFamily.volume);
    });

    test('onza contra onza no se rompe', () {
      expect(convertUnit(5, 'oz', 'oz'), closeTo(5, 1e-9));
      expect(areConvertible('oz', 'onzas'), isTrue);
    });

    test('la onza ahora convierte con AMBAS familias', () {
      expect(areConvertible('oz', 'ml'), isTrue);
      expect(areConvertible('oz', 'kg'), isTrue);
      expect(areConvertible('oz', 'lb'), isTrue);
      // pero volumen y peso siguen sin tocarse entre sí
      expect(areConvertible('ml', 'kg'), isFalse);
    });

    test('la libra está en el selector del formulario de insumo', () {
      // Su ausencia es lo que empujaba a escoger «L» (litro) para el pastrami.
      expect(baseUnitOptions, contains('lb'));
      expect(baseUnitOptions, contains('L'));
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
      // `oz` ↔ `g` ahora SÍ: la onza toma la familia de su contraparte.
      // Ese cambio es a propósito — sin él una receta de peso escrita en
      // onzas no convertía y se guardaba cruda.
      expect(areConvertible('oz', 'g'), isTrue);
      expect(areConvertible('botella', 'ml'), isFalse);
      // lo que sigue prohibido: volumen contra peso sin onza de por medio.
      expect(areConvertible('ml', 'g'), isFalse);
      expect(areConvertible('L', 'lb'), isFalse);
    });
  });
}
