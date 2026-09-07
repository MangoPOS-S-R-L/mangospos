import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/inventory/unit_conversion.dart';
import 'package:mangopos/presentation/settings/more settings/menus/modifiers/state/modifier_ingredient_drafts.dart';
import 'package:mangopos/presentation/settings/more settings/menus/modifiers/state/modifiers_state.dart';

/// Catálogo de prueba: el queso se lleva en gramos, el pan por unidad y el ron
/// en ml comprado por botella de 700.
final _items = <ModifierInventoryItem>[
  const ModifierInventoryItem(
    id: 'queso',
    name: 'Queso cheddar',
    sku: 'Q-1',
    unit: 'g',
    cost: 0.4,
  ),
  const ModifierInventoryItem(
    id: 'pan-sobao',
    name: 'Pan sobao',
    sku: 'P-1',
    unit: 'unidad',
    cost: 12,
  ),
  const ModifierInventoryItem(
    id: 'pan-integral',
    name: 'Pan integral',
    sku: 'P-2',
    unit: 'unidad',
    cost: 18,
  ),
  const ModifierInventoryItem(
    id: 'ron',
    name: 'Ron añejo',
    sku: 'R-1',
    unit: 'ml',
    cost: 0.9,
    purchaseUnit: 'Botella',
    packSize: 700,
  ),
];

ModifierIngredientInput _row(
  String? id,
  String qty,
  String unit, {
  bool deducts = true,
}) =>
    ModifierIngredientInput(
      inventoryItemId: id,
      quantityText: qty,
      unitText: unit,
      deducts: deducts,
    );

void main() {
  group('buildModifierIngredientDrafts', () {
    test('«Queso extra»: 0.05 kg se guardan como 50 g positivos', () {
      final drafts = buildModifierIngredientDrafts(
        rows: [_row('queso', '0.05', 'kg')],
        inventoryItems: _items,
      );

      expect(drafts, hasLength(1));
      expect(drafts.single.inventoryItemId, 'queso');
      expect(drafts.single.quantity, closeTo(50, 1e-9));
      expect(drafts.single.unit, 'g');
    });

    test('«Sin queso»: la misma cantidad, pero NEGATIVA', () {
      final drafts = buildModifierIngredientDrafts(
        rows: [_row('queso', '50', 'g', deducts: false)],
        inventoryItems: _items,
      );

      expect(drafts.single.quantity, closeTo(-50, 1e-9));
    });

    test('cambio de pan: agrega el nuevo y quita el de la receta base', () {
      final drafts = buildModifierIngredientDrafts(
        rows: [
          _row('pan-integral', '1', 'unidad'),
          _row('pan-sobao', '1', 'unidad', deducts: false),
        ],
        inventoryItems: _items,
      );

      expect(drafts, hasLength(2));
      expect(drafts[0].inventoryItemId, 'pan-integral');
      expect(drafts[0].quantity, 1);
      expect(drafts[1].inventoryItemId, 'pan-sobao');
      expect(drafts[1].quantity, -1);
      // Se anulan entre sí: el sándwich sigue llevando UN pan.
      expect(drafts.fold<double>(0, (s, d) => s + d.quantity), 0);
    });

    test('unidad de compra: 1 botella son 700 ml', () {
      final drafts = buildModifierIngredientDrafts(
        rows: [_row('ron', '1', 'Botella')],
        inventoryItems: _items,
      );

      expect(drafts.single.quantity, closeTo(700, 1e-9));
      expect(drafts.single.unit, 'ml');
    });

    test('onza contra un insumo de peso pesa 28.35 g, no 29.57 ml', () {
      final drafts = buildModifierIngredientDrafts(
        rows: [_row('queso', '2', 'oz')],
        inventoryItems: _items,
      );

      expect(drafts.single.quantity, closeTo(56.699, 0.001));
    });

    test('la coma decimal vale igual que el punto', () {
      final drafts = buildModifierIngredientDrafts(
        rows: [_row('queso', '0,05', 'kg')],
        inventoryItems: _items,
      );

      expect(drafts.single.quantity, closeTo(50, 1e-9));
    });

    test('filas vacías, en cero o ilegibles se descartan', () {
      final drafts = buildModifierIngredientDrafts(
        rows: [
          _row(null, '1', 'unidad'),
          _row('', '1', 'unidad'),
          _row('queso', '', 'g'),
          _row('queso', '0', 'g'),
          _row('queso', 'abc', 'g'),
        ],
        inventoryItems: _items,
      );

      expect(drafts, isEmpty);
    });

    test('insumo repetido: gana la primera fila (índice único en la tabla)', () {
      final drafts = buildModifierIngredientDrafts(
        rows: [
          _row('queso', '30', 'g'),
          _row('queso', '80', 'g', deducts: false),
        ],
        inventoryItems: _items,
      );

      expect(drafts, hasLength(1));
      expect(drafts.single.quantity, 30);
    });

    test('insumo que no está en el catálogo: se guarda tal cual en «unidad»', () {
      final drafts = buildModifierIngredientDrafts(
        rows: [_row('fantasma', '3', 'g')],
        inventoryItems: _items,
      );

      expect(drafts.single.quantity, 3);
      expect(drafts.single.unit, 'unidad');
    });
  });

  group('toBaseQuantity / unitOptionsFor', () {
    test('unidad desconocida: se asume que ya venía en unidad base', () {
      expect(
        toBaseQuantity(quantity: 5, fromUnit: 'puñado', baseUnit: 'g'),
        5,
      );
    });

    test('packSize inválido no anula la cantidad', () {
      expect(
        toBaseQuantity(
          quantity: 2,
          fromUnit: 'Caja',
          baseUnit: 'unidad',
          purchaseUnit: 'Caja',
          packSize: 0,
        ),
        2,
      );
    });

    test('las opciones de unidad incluyen la familia y la unidad de compra', () {
      final opts = unitOptionsFor(baseUnit: 'ml', purchaseUnit: 'Botella');
      expect(opts, containsAll(<String>['ml', 'L', 'oz', 'Botella']));

      final peso = unitOptionsFor(baseUnit: 'g');
      expect(peso, containsAll(<String>['g', 'kg', 'lb', 'oz']));

      // Conteo: no hay familia que ofrecer, solo la base.
      expect(unitOptionsFor(baseUnit: 'unidad'), <String>['unidad']);
    });
  });
}
