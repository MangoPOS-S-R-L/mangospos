import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/inventory/item_presentations.dart';

void main() {
  group('checkPresentations', () {
    test('dos niveles: Lata 355 mL y Caja 24 Lata = 8520 mL, con la etiqueta encadenada', () {
      final check = checkPresentations(const [
        PresentationDraft(unit: 'Caja', containsQty: 24, containsUnit: 'lata', isPurchaseDefault: true),
        PresentationDraft(unit: 'Lata', containsQty: 355),
      ], 'ml');
      expect(check.isValid, isTrue, reason: check.errors.join('\n'));
      final caja = check.items.first;
      expect(caja.baseQty, 8520);
      expect(caja.parent, 'Lata', reason: 'el nombre como está en su fila, no como se tecleó');
      expect(check.purchaseDefault!.unit, 'Caja');
      expect(presentationChainLabel(caja, 'ml'), '1 Caja · 24 Lata · 8.52 L');
      expect(presentationChainLabel(check.items.last, 'ml'), '1 Lata · 355 mL');
    });

    test('contener la unidad base por su nombre cuenta como base', () {
      final check = checkPresentations(const [
        PresentationDraft(unit: 'Bloque', containsQty: 5, containsUnit: 'LB'),
      ], 'lb');
      expect(check.isValid, isTrue, reason: check.errors.join('\n'));
      expect(check.items.single.baseQty, 5);
      expect(check.items.single.parent, isNull);
    });

    test('repetida, igual a la base, cantidad 0 y dos de compra por defecto', () {
      final check = checkPresentations(const [
        PresentationDraft(unit: 'Caja', containsQty: 24, isPurchaseDefault: true),
        PresentationDraft(unit: ' caja', containsQty: 12, isPurchaseDefault: true),
        PresentationDraft(unit: 'mL', containsQty: 1),
        PresentationDraft(unit: 'Lata', containsQty: 0),
      ], 'ml');
      expect(check.errors, [
        '«caja» está repetida.',
        '«mL» es la unidad base del insumo.',
        '«Lata» necesita una cantidad mayor que 0.',
        'Solo una puede ser la de compra por defecto.',
      ]);
      expect(check.isValid, isFalse);
    });

    test('tres niveles, contenedor inexistente y contenerse a sí misma', () {
      final check = checkPresentations(const [
        PresentationDraft(unit: 'Lata', containsQty: 355),
        PresentationDraft(unit: 'Caja', containsQty: 24, containsUnit: 'Lata'),
        PresentationDraft(unit: 'Pallet', containsQty: 50, containsUnit: 'Caja'),
        PresentationDraft(unit: 'Six pack', containsQty: 6, containsUnit: 'Botella'),
        PresentationDraft(unit: 'Bulto', containsQty: 2, containsUnit: 'bulto'),
      ], 'ml');
      expect(check.errors, [
        '«Pallet» contiene «Caja», que ya contiene otra presentación: máximo dos niveles.',
        '«Six pack» contiene «Botella», que no está en la lista.',
        '«Bulto» no puede contenerse a sí misma.',
      ]);
      expect(check.items[1].baseQty, 8520);
      expect(check.items[2].baseQty, isNull);
    });

    test('más de 5 no se puede', () {
      final check = checkPresentations([
        for (var i = 0; i < 6; i++) PresentationDraft(unit: 'P$i', containsQty: 1),
      ], 'unidad');
      expect(check.errors, contains('Máximo 5 presentaciones.'));
    });
  });

  test('humanizeBaseQty', () {
    expect(humanizeBaseQty(8520, 'ml'), '8.52 L');
    expect(humanizeBaseQty(500, 'ml'), '500 mL');
    expect(humanizeBaseQty(2500, 'g'), '2.5 kg');
    expect(humanizeBaseQty(24, 'unidad'), startsWith('24 '));
  });

  test('fromMap y toJson van y vuelven', () {
    final d = PresentationDraft.fromMap({
      'unit': 'Caja',
      'contains_qty': '24',
      'contains_unit': 'Lata',
      'is_purchase_default': true,
    });
    expect(d.containsQty, 24);
    expect(d.toJson(), {
      'unit': 'Caja',
      'contains_qty': 24.0,
      'contains_unit': 'Lata',
      'is_purchase_default': true,
    });
    expect(
      PresentationDraft.fromMap({'unit': 'Lata', 'contains_qty': 355, 'contains_unit': ''}).containsUnit,
      isNull,
    );
  });
}
