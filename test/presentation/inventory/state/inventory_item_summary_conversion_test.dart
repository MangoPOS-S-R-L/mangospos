import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';

void main() {
  test('lee la equivalencia cuando la lectura la trae', () {
    final item = InventoryItemSummary.fromMap(
      {
        'id': 'a',
        'name': 'AGUACATE',
        'unit': 'unidad',
        'conversion_unit': 'g',
        'conversion_factor': 200,
      },
      stock: 0,
    );
    expect(item.conversionKnown, isTrue);
    expect(item.conversionUnit, 'g');
    expect(item.conversionFactor, 200);
    expect(item.hasConversion, isTrue);
  });

  test('sin las columnas (migración sin aplicar) NO la da por conocida', () {
    // Es lo que evita que guardar la ficha borre una equivalencia que existe
    // pero que esta lectura no trajo.
    final item = InventoryItemSummary.fromMap(
      {'id': 'a', 'name': 'AGUACATE', 'unit': 'unidad'},
      stock: 0,
    );
    expect(item.conversionKnown, isFalse);
    expect(item.hasConversion, isFalse);
  });

  test('columnas presentes pero vacías = conocida y sin equivalencia', () {
    final item = InventoryItemSummary.fromMap(
      {
        'id': 'a',
        'unit': 'unidad',
        'conversion_unit': null,
        'conversion_factor': null,
      },
      stock: 0,
    );
    expect(item.conversionKnown, isTrue);
    expect(item.hasConversion, isFalse);
  });
}
