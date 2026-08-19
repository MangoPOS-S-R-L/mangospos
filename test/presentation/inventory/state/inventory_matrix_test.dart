// Reglas de lectura de Insumos v2: la matriz insumo × bodega y el criterio
// de "bajo mínimo". Ambas cosas deciden qué ve el encargado de bodega, así
// que se prueban contra la misma regla que la vista SQL `v_inventory_low_stock`.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';

InventoryItemSummary _item({
  String id = 'i1',
  double stock = 0,
  double minStock = 0,
  bool isActive = true,
}) {
  return InventoryItemSummary(
    id: id,
    sku: 'INS-0001',
    name: 'Insumo',
    description: '',
    unit: 'kg',
    cost: 10,
    minStock: minStock,
    maxStock: null,
    isActive: isActive,
    stock: stock,
  );
}

void main() {
  group('bajo mínimo', () {
    test('un insumo sin mínimo configurado NO es alerta aunque esté en cero', () {
      final item = _item(stock: 0, minStock: 0);
      expect(item.isLowStock, isFalse);
      expect(item.lowStockLevel, isNull);
      expect(item.shortfall, 0);
    });

    test('en o por debajo del mínimo es alerta', () {
      expect(_item(stock: 10, minStock: 10).isLowStock, isTrue);
      expect(_item(stock: 11, minStock: 10).isLowStock, isFalse);
    });

    test('la severidad sigue el alert_level de la vista SQL', () {
      expect(_item(stock: 0, minStock: 10).lowStockLevel, 'out_of_stock');
      expect(_item(stock: 5, minStock: 10).lowStockLevel, 'critical');
      expect(_item(stock: 9, minStock: 10).lowStockLevel, 'low');
    });

    test('un insumo inactivo no genera alerta', () {
      expect(_item(stock: 0, minStock: 10, isActive: false).isLowStock, isFalse);
    });

    test('el faltante es lo que hay que reponer, nunca negativo', () {
      expect(_item(stock: 4, minStock: 10).shortfall, 6);
      expect(_item(stock: 40, minStock: 10).shortfall, 0);
    });
  });

  group('InventoryStockMatrix', () {
    final matrix = InventoryStockMatrix(
      items: [_item(id: 'ron', stock: 6750, minStock: 9000)],
      byWarehouse: const {
        'ron': {'principal': 3000, 'cocina': 0, 'bar': 3750},
      },
    );

    test('distingue "hay cero" de "nunca estuvo acá"', () {
      expect(matrix.hasStockRow('ron', 'cocina'), isTrue);
      expect(matrix.quantityOf('ron', 'cocina'), 0);
      expect(matrix.hasStockRow('ron', 'naco'), isFalse);
      expect(matrix.quantityOf('ron', 'naco'), 0);
    });

    test('solo lista las bodegas con existencia real', () {
      expect(matrix.warehousesWithStock('ron'), ['principal', 'bar']);
      expect(matrix.warehousesWithStock('desconocido'), isEmpty);
    });
  });
}
