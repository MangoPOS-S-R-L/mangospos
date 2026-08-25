import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/utils/bogo_promo_allocator.dart';

BogoLine _line(
  String id, {
  required int qty,
  required double unit,
  String? checkId,
  String? productId,
}) => BogoLine(
  id: id,
  quantity: qty,
  gross: unit * qty,
  checkId: checkId,
  productId: productId ?? 'p-generico',
);

double _sum(Map<String, double> m) =>
    m.values.fold<double>(0, (a, b) => a + b);

void main() {
  group('allocateBogoDiscounts — 2x1 con varios productos en la misma oferta', () {
    // Bug prod 2026-08-24, mesa A21: se juntaban TODOS los productos de la
    // oferta en un pozo y las unidades gratis salían todas del más barato.
    test('2 Margaritas (400) + 2 Palomas (430) → 1 gratis de CADA una', () {
      final result = allocateBogoDiscounts(
        lines: [
          _line('m', qty: 2, unit: 400, productId: 'margarita'),
          _line('p', qty: 2, unit: 430, productId: 'paloma'),
        ],
        buyQuantity: 2,
        freeQuantity: 1,
      );

      expect(result['m'], 400);
      expect(result['p'], 430);
      expect(_sum(result), 830); // antes: 800 con la Margarita en RD$0.00
    });

    test('4 Margaritas + 2 Palomas → 2 gratis y 1 gratis', () {
      final result = allocateBogoDiscounts(
        lines: [
          _line('m', qty: 4, unit: 400, productId: 'margarita'),
          _line('p', qty: 2, unit: 430, productId: 'paloma'),
        ],
        buyQuantity: 2,
        freeQuantity: 1,
      );

      expect(result['m'], 800);
      expect(result['p'], 430);
      expect(_sum(result), 1230); // antes: 1200, todo de la Margarita
    });

    test('ningún producto llega a la cantidad → no descuenta nada', () {
      final result = allocateBogoDiscounts(
        lines: [
          _line('m', qty: 1, unit: 400, productId: 'margarita'),
          _line('p', qty: 1, unit: 430, productId: 'paloma'),
        ],
        buyQuantity: 2,
        freeQuantity: 1,
      );

      expect(result, isEmpty);
    });
  });

  group('allocateBogoDiscounts — regresiones ya cerradas', () {
    test('cuenta UNIDADES, no filas: qty=3 + qty=1 en un 4x3 libera 1 unidad', () {
      final result = allocateBogoDiscounts(
        lines: [
          _line('a', qty: 3, unit: 275, productId: 'blue-moon'),
          _line('b', qty: 1, unit: 275, productId: 'blue-moon'),
        ],
        buyQuantity: 4,
        freeQuantity: 1,
      );

      // Descuento parcial de fila: 275 (una unidad), nunca 825 (la fila).
      expect(_sum(result), 275);
      expect(result.values.every((value) => value == 275), isTrue);
    });

    test('no contamina entre cuentas: cada check arma su propia oferta', () {
      final result = allocateBogoDiscounts(
        lines: [
          _line('c1', qty: 2, unit: 400, checkId: 'check-1', productId: 'mar'),
          _line('c2', qty: 2, unit: 400, checkId: 'check-2', productId: 'mar'),
        ],
        buyQuantity: 2,
        freeQuantity: 1,
      );

      expect(result['c1'], 400);
      expect(result['c2'], 400);
    });

    test('cuentas distintas no se suman para completar la oferta', () {
      final result = allocateBogoDiscounts(
        lines: [
          _line('c1', qty: 1, unit: 400, checkId: 'check-1', productId: 'mar'),
          _line('c2', qty: 1, unit: 400, checkId: 'check-2', productId: 'mar'),
        ],
        buyQuantity: 2,
        freeQuantity: 1,
      );

      expect(result, isEmpty);
    });

    test('la unidad gratis sale de la más barata del mismo producto', () {
      // Misma Margarita: una fila con extra (500/u) y otra sin extra (400/u).
      final result = allocateBogoDiscounts(
        lines: [
          _line('con-extra', qty: 1, unit: 500, productId: 'mar'),
          _line('simple', qty: 1, unit: 400, productId: 'mar'),
        ],
        buyQuantity: 2,
        freeQuantity: 1,
      );

      expect(result['simple'], 400);
      expect(result.containsKey('con-extra'), isFalse);
    });

    test('reparto determinista: el orden de entrada no cambia el resultado', () {
      final lines = [
        _line('a', qty: 1, unit: 400, productId: 'mar'),
        _line('b', qty: 1, unit: 400, productId: 'mar'),
        _line('c', qty: 2, unit: 430, productId: 'paloma'),
      ];
      final directo = allocateBogoDiscounts(
        lines: lines,
        buyQuantity: 2,
        freeQuantity: 1,
      );
      final invertido = allocateBogoDiscounts(
        lines: lines.reversed.toList(),
        buyQuantity: 2,
        freeQuantity: 1,
      );

      expect(invertido, directo);
      expect(directo['a'], 400); // empate por precio → desempata el id
      expect(directo['c'], 430);
    });

    test('3x2: 6 unidades liberan 2', () {
      final result = allocateBogoDiscounts(
        lines: [_line('a', qty: 6, unit: 100, productId: 'x')],
        buyQuantity: 3,
        freeQuantity: 1,
      );

      expect(result['a'], 200);
    });

    test('configuración inválida no descuenta', () {
      expect(
        allocateBogoDiscounts(
          lines: [_line('a', qty: 4, unit: 100)],
          buyQuantity: 1,
          freeQuantity: 1,
        ),
        isEmpty,
      );
      expect(
        allocateBogoDiscounts(
          lines: [_line('a', qty: 4, unit: 100)],
          buyQuantity: 2,
          freeQuantity: 0,
        ),
        isEmpty,
      );
    });
  });
}
