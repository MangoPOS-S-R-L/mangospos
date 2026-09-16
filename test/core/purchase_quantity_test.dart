import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/inventory/purchase_quantity.dart';

void main() {
  group('roundUpToPurchase — con empaque', () {
    test('10 latas sugeridas y caja de 24 → 1 caja, sobran 14', () {
      final r = roundUpToPurchase(suggestedBase: 10, packSize: 24);
      expect(r.packs, 1);
      expect(r.baseQuantity, 24);
      expect(r.surplusBase, 14);
      expect(r.raisedToMinimum, isFalse);
    });

    test('justo dos cajas no sube a tres', () {
      final r = roundUpToPurchase(suggestedBase: 48, packSize: 24);
      expect(r.packs, 2);
      expect(r.surplusBase, 0);
    });

    test('una lata de más ya es otra caja', () {
      expect(roundUpToPurchase(suggestedBase: 49, packSize: 24).packs, 3);
    });

    test('empaque en mL: botella de 750 y 1000 sugeridos → 2 botellas', () {
      final r = roundUpToPurchase(
        suggestedBase: 1000,
        packSize: 750,
        baseIsCountable: false,
      );
      expect(r.packs, 2);
      expect(r.baseQuantity, 1500);
      expect(r.surplusBase, 500);
    });

    test('la coma flotante no agrega un empaque fantasma', () {
      // 0.1 + 0.2 = 0.30000000000000004; dividido entre 0.1 da 3.0000000000000004.
      final r = roundUpToPurchase(suggestedBase: 0.1 + 0.2, packSize: 0.1);
      expect(r.packs, 3);
    });

    test('mínimo de compra del suplidor sube la cantidad y lo avisa', () {
      final r = roundUpToPurchase(
        suggestedBase: 10,
        packSize: 24,
        minOrderPacks: 5,
      );
      expect(r.packs, 5);
      expect(r.baseQuantity, 120);
      expect(r.surplusBase, 110);
      expect(r.raisedToMinimum, isTrue);
    });

    test('el mínimo NO se fuerza cuando no hace falta pedir nada', () {
      final r = roundUpToPurchase(
        suggestedBase: 0,
        packSize: 24,
        minOrderPacks: 5,
      );
      expect(r.packs, 0);
      expect(r.baseQuantity, 0);
    });
  });

  group('roundUpToPurchase — sin empaque', () {
    test('base contable: enteros hacia arriba', () {
      final r = roundUpToPurchase(suggestedBase: 2.2);
      expect(r.packs, 3);
      expect(r.baseQuantity, 3);
      expect(r.surplusBase, closeTo(0.8, 1e-9));
    });

    test('base medible: 2.5 lb se compran tal cual', () {
      final r = roundUpToPurchase(suggestedBase: 2.5, baseIsCountable: false);
      expect(r.packs, 2.5);
      expect(r.baseQuantity, 2.5);
      expect(r.surplusBase, 0);
    });

    test('negativo o cero → no se pide', () {
      expect(roundUpToPurchase(suggestedBase: -4).baseQuantity, 0);
    });

    test('empaque inválido (0) cuenta como sin empaque', () {
      expect(roundUpToPurchase(suggestedBase: 3.5, packSize: 0).packs, 4);
    });
  });

  test('tiempo de entrega por defecto (D9) es 2 días', () {
    expect(kDefaultSupplierLeadTimeDays, 2);
  });
}
