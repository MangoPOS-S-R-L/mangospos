import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/inventory/unit_conversion.dart';

void main() {
  group('catálogo — lectura de lo que ya está guardado', () {
    test('cada código, nombre, abreviatura y alias apunta a UNA sola unidad',
        () {
      // Si dos unidades comparten una clave, la segunda se vuelve inalcanzable
      // en silencio. Funda comparte «BG» con Saco a propósito (matchAbbr).
      for (final def in unitCatalog) {
        final keys = [
          def.code,
          def.label,
          if (def.matchAbbr) def.abbr,
          ...def.aliases,
        ];
        for (final key in keys) {
          expect(identical(findUnit(key), def), isTrue,
              reason: '«$key» debería ser ${def.code} y es '
                  '${findUnit(key)?.code}');
        }
      }
    });

    test('lo escrito a mano en Penda cae en su unidad del catálogo', () {
      expect(normalizeUnitCode('CAJAS'), 'Caja');
      expect(normalizeUnitCode('caja'), 'Caja');
      expect(normalizeUnitCode('LIBRA'), 'lb');
      expect(normalizeUnitCode('GALONES'), 'gal');
      expect(normalizeUnitCode('Galón'), 'gal');
      expect(normalizeUnitCode('SACO'), 'Saco');
      expect(normalizeUnitCode('botella'), 'Botella');
      expect(normalizeUnitCode('bolsa'), 'Funda');
      expect(normalizeUnitCode('gr'), 'g');
      expect(normalizeUnitCode('lt'), 'L');
      expect(normalizeUnitCode('fl. oz'), 'fl oz');
      expect(normalizeUnitCode('ea'), 'unidad');
    });

    test('los códigos que ya había se guardan igual', () {
      for (final code in ['unidad', 'ml', 'L', 'g', 'kg', 'lb', 'oz']) {
        expect(normalizeUnitCode(code), code);
      }
    });

    test('las abreviaturas de Toast se reconocen', () {
      expect(findUnit('CS')?.code, 'Caja');
      expect(findUnit('BTL')?.code, 'Botella');
      expect(findUnit('BG')?.code, 'Saco');
      expect(findUnit('FLAT')?.code, 'Cartón');
      expect(findUnit('dz')?.code, 'dz');
    });

    test('lo que no está en el catálogo se conserva tal cual', () {
      expect(findUnit('manojo'), isNull);
      expect(normalizeUnitCode(' manojo '), 'manojo');
      expect(findUnit(''), isNull);
      expect(findUnit(null), isNull);
    });

    test('clases', () {
      expect(findUnit('lb')!.unitClass, UnitClass.weight);
      expect(findUnit('gal')!.unitClass, UnitClass.volume);
      expect(findUnit('dz')!.unitClass, UnitClass.count);
      expect(findUnit('Caja')!.unitClass, UnitClass.container);
    });

    test('sameUnit compara la unidad, no el texto', () {
      expect(sameUnit('CAJAS', 'Caja'), isTrue);
      expect(sameUnit('lb', 'libras'), isTrue);
      expect(sameUnit('oz', 'fl oz'), isFalse);
      expect(sameUnit('manojo', 'MANOJO'), isTrue);
      expect(sameUnit('', 'unidad'), isFalse);
    });
  });

  group('catálogo — cómo se muestra', () {
    test('etiqueta corta', () {
      expect(unitShortLabel('unidad'), 'ea');
      expect(unitShortLabel('ml'), 'mL');
      expect(unitShortLabel('fl oz'), 'fl oz');
      expect(unitShortLabel('CAJAS'), 'Caja');
      expect(unitShortLabel('manojo'), 'manojo');
    });

    test('etiqueta del menú', () {
      expect(unitMenuLabel('lb'), 'Libra (lb)');
      expect(unitMenuLabel('Caja'), 'Caja (CS)');
      expect(unitMenuLabel('unidad'), 'Unidad (ea)');
      expect(unitMenuLabel('porcion'), 'Porción');
    });

    test('empaque al estilo Toast', () {
      expect(
        packLabel(packSize: 24, baseUnit: 'unidad', purchaseUnit: 'Caja'),
        '24 ea / Caja',
      );
      expect(
        packLabel(packSize: 750, baseUnit: 'ml', purchaseUnit: 'Botella'),
        '750 mL / Botella',
      );
      expect(
        packLabel(packSize: 50, baseUnit: 'lb', purchaseUnit: 'SACO'),
        '50 lb / Saco',
      );
      expect(
        packLabel(packSize: 453.59237, baseUnit: 'g', purchaseUnit: 'lb'),
        '453.59 g / lb',
      );
    });

    test('formatUnitQty no deja ceros sobrantes', () {
      expect(formatUnitQty(24), '24');
      expect(formatUnitQty(2.5), '2.5');
      expect(formatUnitQty(0.0625), '0.0625');
      expect(formatUnitQty(0), '0');
    });
  });

  group('catálogo — selectores', () {
    test('la base ofrece peso, volumen y conteo; nunca un contenedor', () {
      expect(baseUnitSections().map((s) => s.title),
          ['Peso', 'Volumen', 'Conteo']);
      expect(baseUnitOptions,
          containsAll(<String>['unidad', 'lb', 'L', 'oz', 'fl oz', 'gal']));
      expect(baseUnitOptions.any((c) => findUnit(c)!.isContainer), isFalse);
    });

    test('la compra ofrece contenedores primero y también medidas', () {
      expect(purchaseUnitSections().map((s) => s.title),
          ['Contenedor', 'Peso', 'Volumen', 'Conteo']);
      expect(purchaseUnitOptions,
          containsAll(<String>['Caja', 'Saco', 'Funda', 'Botella', 'lb', 'gal']));
    });

    test('mg y cl convierten pero no se ofrecen', () {
      expect(baseUnitOptions, isNot(contains('mg')));
      expect(baseUnitOptions, isNot(contains('cl')));
      expect(convertUnit(1, 'cl', 'ml'), 10);
    });

    test('una base fuera del catálogo queda en «Actual» y seleccionada', () {
      final sections = baseUnitSections(current: 'bolsa');
      expect(sections.first.legacy, isTrue);
      expect(sections.first.codes, ['bolsa']);
      expect(unitSelectionValue(sections, 'bolsa', fallback: 'unidad'),
          'bolsa');
    });

    test('un alias selecciona su unidad sin sección «Actual»', () {
      final base = baseUnitSections(current: 'gr');
      expect(base.any((s) => s.legacy), isFalse);
      expect(unitSelectionValue(base, 'gr', fallback: 'unidad'), 'g');

      final compra = purchaseUnitSections(current: 'CAJAS');
      expect(compra.any((s) => s.legacy), isFalse);
      expect(unitSelectionValue(compra, 'CAJAS', fallback: ''), 'Caja');
    });

    test('sin valor guardado cae al fallback', () {
      expect(unitSelectionValue(baseUnitSections(), null, fallback: 'unidad'),
          'unidad');
      expect(unitSelectionValue(purchaseUnitSections(), '', fallback: ''), '');
    });

    test('matchUnitOption', () {
      expect(matchUnitOption(['g', 'kg'], 'GR'), 'g');
      expect(matchUnitOption(['g', 'kg'], 'ml'), isNull);
    });
  });

  group('conversión — unidades nuevas', () {
    test('galón, cuarto, taza, cucharada y cucharadita', () {
      expect(convertUnit(1, 'gal', 'ml'), closeTo(3785.411784, 1e-6));
      // Todo sale del galón de EE. UU.: el cuarto es 3785.411784 ÷ 4.
      expect(convertUnit(1, 'qt', 'ml'), closeTo(946.352946, 1e-6));
      expect(convertUnit(1, 'gal', 'qt'), closeTo(4, 1e-6));
      expect(convertUnit(1, 'gal', 'fl oz'), closeTo(128, 0.01));
      expect(convertUnit(1, 'cup', 'tbsp'), closeTo(16, 1e-6));
      expect(convertUnit(1, 'tbsp', 'tsp'), closeTo(3, 1e-6));
    });

    test('la docena son 12 unidades', () {
      expect(convertUnit(2, 'dz', 'unidad'), 24);
      expect(convertUnit(1, 'docena', 'ea'), 12);
    });

    test('fl oz es SIEMPRE volumen', () {
      expect(convertUnit(1, 'fl oz', 'ml'), closeTo(29.5735, 1e-4));
      expect(convertUnit(1, 'fl oz', 'g'), isNull);
      expect(unitFamily('fl oz'), UnitFamily.volume);
    });

    test('la oz a secas sigue resolviéndose por contexto', () {
      expect(convertUnit(1, 'oz', 'g'), closeTo(28.349523125, 1e-9));
      expect(convertUnit(1, 'oz', 'ml'), closeTo(29.5735, 1e-4));
    });

    test('porción, rebanada y contenedores no convierten', () {
      expect(convertUnit(1, 'porcion', 'unidad'), isNull);
      expect(convertUnit(1, 'Caja', 'unidad'), isNull);
      expect(unitFamily('Caja'), UnitFamily.unknown);
    });
  });

  group('empaque — contenido automático', () {
    test('si se compra en una medida, el contenido sale solo', () {
      expect(autoPackSize(purchaseUnit: 'lb', baseUnit: 'g'),
          closeTo(453.59237, 1e-5));
      expect(autoPackSize(purchaseUnit: 'GALON', baseUnit: 'ml'),
          closeTo(3785.411784, 1e-6));
      expect(autoPackSize(purchaseUnit: 'dz', baseUnit: 'unidad'), 12);
      expect(autoPackSize(purchaseUnit: 'kg', baseUnit: 'lb'),
          closeTo(2.20462, 1e-5));
      expect(autoPackSize(purchaseUnit: 'lb', baseUnit: 'oz'), closeTo(16, 1e-9));
    });

    test('un contenedor o una medida que no convierte → hay que escribirlo',
        () {
      expect(autoPackSize(purchaseUnit: 'Caja', baseUnit: 'unidad'), isNull);
      // Aguacates por libra: cuántos trae una libra lo dice el negocio.
      expect(autoPackSize(purchaseUnit: 'lb', baseUnit: 'unidad'), isNull);
      expect(autoPackSize(purchaseUnit: 'manojo', baseUnit: 'unidad'), isNull);
    });

    test('resolvePackSize', () {
      expect(resolvePackSize(purchaseUnit: '', baseUnit: 'ml', manual: 24), 1);
      expect(
          resolvePackSize(purchaseUnit: 'Caja', baseUnit: 'unidad', manual: 24),
          24);
      expect(
          resolvePackSize(purchaseUnit: 'Caja', baseUnit: 'unidad', manual: null),
          1);
      // La conversión manda sobre lo escrito.
      expect(resolvePackSize(purchaseUnit: 'lb', baseUnit: 'g', manual: 999),
          closeTo(453.59237, 1e-5));
    });
  });

  group('recetas — opciones y descuento', () {
    test('la unidad de compra escrita de otra forma sigue multiplicando', () {
      expect(
        toBaseQuantity(
          quantity: 2,
          fromUnit: 'Caja',
          baseUnit: 'unidad',
          purchaseUnit: 'CAJAS',
          packSize: 24,
        ),
        48,
      );
    });

    test('un galón escrito en la receta convierte a ml', () {
      expect(
        toBaseQuantity(quantity: 1, fromUnit: 'gal', baseUnit: 'ml'),
        closeTo(3785.411784, 1e-6),
      );
    });

    test('base oz a secas: se ofrecen peso y volumen', () {
      final opts = unitOptionsFor(baseUnit: 'oz');
      expect(opts, containsAll(<String>['g', 'lb', 'ml', 'fl oz']));
    });

    test('la base se normaliza y no se duplica la unidad de compra', () {
      expect(unitOptionsFor(baseUnit: 'gr').first, 'g');
      final opts = unitOptionsFor(baseUnit: 'lb', purchaseUnit: 'LIBRA');
      expect(opts.where((u) => u == 'lb'), hasLength(1));
      expect(opts, isNot(contains('LIBRA')));
    });

    test('current conserva una unidad vieja que convierte, no una ajena', () {
      expect(unitOptionsFor(baseUnit: 'ml', current: 'cl'), contains('cl'));
      expect(unitOptionsFor(baseUnit: 'g', current: 'ml'), isNot(contains('ml')));
    });
  });

  group('equivalencia propia del insumo', () {
    test('400 g de aguacate son 2 aguacates si 1 ea = 200 g', () {
      expect(
        toBaseQuantity(
          quantity: 400,
          fromUnit: 'g',
          baseUnit: 'unidad',
          conversionUnit: 'g',
          conversionFactor: 200,
        ),
        closeTo(2, 1e-9),
      );
      // En libras también: 453.59 g entre 200 g.
      expect(
        toBaseQuantity(
          quantity: 1,
          fromUnit: 'lb',
          baseUnit: 'unidad',
          conversionUnit: 'g',
          conversionFactor: 200,
        ),
        closeTo(2.26796, 1e-5),
      );
    });

    test('al revés: base en libras y receta en unidades', () {
      // 1 lb = 2.5 tomates → 5 tomates son 2 libras.
      expect(
        toBaseQuantity(
          quantity: 5,
          fromUnit: 'unidad',
          baseUnit: 'lb',
          conversionUnit: 'unidad',
          conversionFactor: 2.5,
        ),
        closeTo(2, 1e-9),
      );
    });

    test('densidad: con 1 mL = 0.92 g, 92 g son 100 mL', () {
      expect(
        toBaseQuantity(
          quantity: 92,
          fromUnit: 'g',
          baseUnit: 'ml',
          conversionUnit: 'g',
          conversionFactor: 0.92,
        ),
        closeTo(100, 1e-9),
      );
    });

    test('base fuera del catálogo: 1 bolsa = 283 g', () {
      expect(
        toBaseQuantity(
          quantity: 566,
          fromUnit: 'g',
          baseUnit: 'bolsa',
          conversionUnit: 'g',
          conversionFactor: 283,
        ),
        closeTo(2, 1e-9),
      );
    });

    test('la onza como equivalencia es de peso', () {
      // 1 ea = 8 oz: una libra (16 oz) son 2 unidades.
      expect(
        toBaseQuantity(
          quantity: 453.59237,
          fromUnit: 'g',
          baseUnit: 'unidad',
          conversionUnit: 'oz',
          conversionFactor: 8,
        ),
        closeTo(2, 1e-6),
      );
    });

    test('el signo se conserva («sin aguacate»)', () {
      expect(
        toBaseQuantity(
          quantity: -200,
          fromUnit: 'g',
          baseUnit: 'unidad',
          conversionUnit: 'g',
          conversionFactor: 200,
        ),
        closeTo(-1, 1e-9),
      );
    });

    test('sin equivalencia se comporta como antes', () {
      expect(
        toBaseQuantity(quantity: 400, fromUnit: 'g', baseUnit: 'unidad'),
        400,
      );
    });

    test('compra por libra con empaque: 1 lb = 3 ea → 8 oz son 1.5 ea', () {
      expect(
        toBaseQuantity(
          quantity: 8,
          fromUnit: 'oz',
          baseUnit: 'unidad',
          purchaseUnit: 'lb',
          packSize: 3,
        ),
        closeTo(1.5, 1e-9),
      );
    });

    test('opciones: por unidad con 1 ea = 200 g se ofrece el peso', () {
      final opts = unitOptionsFor(baseUnit: 'unidad', conversionUnit: 'g');
      expect(opts.first, 'unidad');
      expect(opts, containsAll(<String>['g', 'kg', 'lb', 'oz']));
      expect(opts, isNot(contains('ml')));
    });

    test('opciones: comprar por libra también abre el peso', () {
      expect(unitOptionsFor(baseUnit: 'unidad', purchaseUnit: 'lb'),
          containsAll(<String>['g', 'lb']));
    });

    test('el contenido del empaque sale de la equivalencia', () {
      expect(
        autoPackSize(
          purchaseUnit: 'lb',
          baseUnit: 'unidad',
          conversionUnit: 'g',
          conversionFactor: 200,
        ),
        closeTo(2.26796, 1e-5),
      );
      expect(autoPackSize(purchaseUnit: 'lb', baseUnit: 'unidad'), isNull);
    });

    test('resolveItemConversion descarta lo que no sirve', () {
      expect(resolveItemConversion(baseUnit: 'unidad', unit: 'g', factor: 200),
          (unit: 'g', factor: 200.0));
      expect(
          resolveItemConversion(baseUnit: 'unidad', unit: 'gramos', factor: 200)
              ?.unit,
          'g');
      expect(resolveItemConversion(baseUnit: 'unidad', unit: 'g', factor: 0),
          isNull);
      expect(resolveItemConversion(baseUnit: 'unidad', unit: '', factor: 200),
          isNull);
      // Misma familia que la base: ya lo sabe el catálogo.
      expect(resolveItemConversion(baseUnit: 'lb', unit: 'g', factor: 453),
          isNull);
      expect(resolveItemConversion(baseUnit: 'lb', unit: 'oz', factor: 16),
          isNull);
      // Un contenedor no es una equivalencia: eso es el empaque.
      expect(resolveItemConversion(baseUnit: 'unidad', unit: 'Caja', factor: 24),
          isNull);
      // La onza vale como peso contra un líquido (densidad).
      expect(resolveItemConversion(baseUnit: 'ml', unit: 'oz', factor: 0.03)
          ?.unit, 'oz');
    });

    test('el selector de equivalencia ofrece las OTRAS clases', () {
      expect(conversionUnitSections(baseUnit: 'unidad').map((s) => s.title),
          ['Peso', 'Volumen']);
      expect(conversionUnitSections(baseUnit: 'lb').map((s) => s.title),
          ['Volumen', 'Conteo']);
      expect(conversionUnitSections(baseUnit: 'bolsa').map((s) => s.title),
          ['Peso', 'Volumen', 'Conteo']);
      final conteo = conversionUnitSections(baseUnit: 'lb').last.codes;
      expect(conteo, containsAll(<String>['unidad', 'dz']));
      expect(conteo, isNot(contains('porcion')));
      // La guardada que ya no aplica queda visible para no romper el campo.
      expect(conversionUnitSections(baseUnit: 'lb', current: 'g').first.legacy,
          isTrue);
    });

    test('conversionLabel', () {
      expect(conversionLabel(baseUnit: 'unidad', unit: 'g', factor: 200),
          '1 ea = 200 g');
      expect(conversionLabel(baseUnit: 'ml', unit: 'g', factor: 0.92),
          '1 mL = 0.92 g');
    });
  });
}
