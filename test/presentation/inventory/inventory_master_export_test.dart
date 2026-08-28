// El maestro de artículos lo abre un contador, no la app: si una columna se
// corre de lugar o el código de barras deja de salir como texto, nadie se
// entera hasta que el archivo ya está afuera. Estas pruebas fijan el orden
// de las columnas, el cálculo del valor y qué se manda a Excel como número.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/services/inventory_master_export.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';

InventoryItemSummary _item({
  String id = 'i1',
  String sku = 'SKU-1',
  String name = 'Ron Brugal',
  String description = '',
  String unit = 'ml',
  String purchaseUnit = '',
  double packSize = 1,
  double cost = 2,
  double minStock = 0,
  double? maxStock,
  bool isActive = true,
  double stock = 0,
  String barcode = '',
  String costingMethod = 'average',
  bool tracksLots = false,
  String itemClassification = 'simple',
}) {
  return InventoryItemSummary(
    id: id,
    sku: sku,
    name: name,
    description: description,
    unit: unit,
    purchaseUnit: purchaseUnit,
    packSize: packSize,
    cost: cost,
    minStock: minStock,
    maxStock: maxStock,
    isActive: isActive,
    stock: stock,
    barcode: barcode,
    costingMethod: costingMethod,
    tracksLots: tracksLots,
    itemClassification: itemClassification,
  );
}

const _bar = InventoryWarehouse(id: 'w1', name: 'Bar', isMain: true);
const _cocina = InventoryWarehouse(id: 'w2', name: 'Cocina', isMain: false);

void main() {
  group('InventoryMasterExport', () {
    test('los cuatro campos pedidos abren el archivo, en orden', () {
      final data = InventoryMasterExport.build(
        items: [
          _item(sku: 'ART-001', name: 'Ron', barcode: '0759', cost: 12.5),
        ],
        warehouses: const [],
        matrix: const InventoryStockMatrix(items: [], byWarehouse: {}),
      );

      expect(data.headers.take(5), [
        'Código',
        'Nombre',
        'Descripción',
        'Código de barras',
        'Costo unitario (DOP)',
      ]);
      expect(data.rows.single.take(5), [
        'ART-001',
        'Ron',
        '',
        '0759',
        '12.50',
      ]);
    });

    test('el código de barras NO va como número (conserva el cero)', () {
      final data = InventoryMasterExport.build(
        items: [_item(barcode: '0759123456789', sku: '0012')],
        warehouses: const [],
        matrix: const InventoryStockMatrix(items: [], byWarehouse: {}),
      );

      expect(data.numericColumns, isNot(contains(0)));
      expect(data.numericColumns, isNot(contains(3)));
      expect(data.moneyColumns, isNot(contains(3)));
      expect(data.rows.single[3], '0759123456789');
    });

    test('una columna por bodega, en el orden de la pantalla', () {
      final data = InventoryMasterExport.build(
        items: [_item(stock: 3000)],
        warehouses: const [_bar, _cocina],
        matrix: const InventoryStockMatrix(
          items: [],
          byWarehouse: {
            'i1': {'w1': 2250, 'w2': 750},
          },
        ),
      );

      final first = data.headers.indexOf('Existencia · Bar');
      expect(first, 13);
      expect(data.headers[14], 'Existencia · Cocina');
      expect(data.rows.single[13], '2250');
      expect(data.rows.single[14], '750');
      // Las columnas dinámicas también tienen que llegar como número.
      expect(data.numericColumns, containsAll(<int>[13, 14]));
    });

    test('la bodega sin fila de stock sale en cero, no vacía', () {
      final data = InventoryMasterExport.build(
        items: [_item(stock: 10)],
        warehouses: const [_bar, _cocina],
        matrix: const InventoryStockMatrix(
          items: [],
          byWarehouse: {
            'i1': {'w1': 10},
          },
        ),
      );

      expect(data.rows.single[14], '0');
    });

    test('el valor de la existencia se calcula sobre la unidad base', () {
      final data = InventoryMasterExport.build(
        items: [_item(cost: 1.5, stock: 4500)],
        warehouses: const [],
        matrix: const InventoryStockMatrix(items: [], byWarehouse: {}),
      );

      expect(data.rows.single[9], '4500'); // existencia total
      expect(data.rows.single[10], '6750.00'); // valor
      expect(data.moneyColumns, containsAll(<int>[4, 8, 10]));
    });

    test('el empaque agrega el costo por unidad de compra', () {
      final data = InventoryMasterExport.build(
        items: [
          _item(cost: 2, packSize: 750, purchaseUnit: 'botella', unit: 'ml'),
        ],
        warehouses: const [],
        matrix: const InventoryStockMatrix(items: [], byWarehouse: {}),
      );

      expect(data.rows.single[6], 'botella');
      expect(data.rows.single[7], '750');
      expect(data.rows.single[8], '1500.00');
    });

    test('sin empaque las columnas de empaque quedan vacías', () {
      final data = InventoryMasterExport.build(
        items: [_item(packSize: 1)],
        warehouses: const [],
        matrix: const InventoryStockMatrix(items: [], byWarehouse: {}),
      );

      expect(data.rows.single[7], '');
      expect(data.rows.single[8], '');
    });

    test('cada fila tiene tantas celdas como encabezados', () {
      final data = InventoryMasterExport.build(
        items: [_item(), _item(id: 'i2', sku: 'SKU-2', maxStock: 10)],
        warehouses: const [_bar, _cocina],
        matrix: const InventoryStockMatrix(items: [], byWarehouse: {}),
      );

      for (final row in data.rows) {
        expect(row.length, data.headers.length);
      }
      expect(data.headers.last, 'ID interno');
    });

    test('el código de la moneda del negocio titula las columnas de dinero',
        () {
      final data = InventoryMasterExport.build(
        items: const [],
        warehouses: const [],
        matrix: const InventoryStockMatrix(items: [], byWarehouse: {}),
        currencyCode: 'USD',
      );

      expect(data.headers[4], 'Costo unitario (USD)');
      expect(data.headers[10], 'Valor existencia (USD)');
    });

    test('las etiquetas salen en español, no en el valor de la BD', () {
      final data = InventoryMasterExport.build(
        items: [
          _item(
            itemClassification: 'raw_material',
            costingMethod: 'fifo',
            tracksLots: true,
            isActive: false,
          ),
        ],
        warehouses: const [],
        matrix: const InventoryStockMatrix(items: [], byWarehouse: {}),
      );

      final row = data.rows.single;
      expect(row[13], 'Materia prima');
      expect(row[14], 'FIFO');
      expect(row[15], 'Sí');
      expect(row[16], 'Inactivo');
    });

    test('el nombre del archivo lleva sello de fecha', () {
      final name = InventoryMasterExport.filename(
        now: DateTime(2026, 8, 28, 9, 5),
      );
      expect(name, 'maestro_articulos_20260828_0905');
    });
  });
}
