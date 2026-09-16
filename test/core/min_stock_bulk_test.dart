import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/inventory/min_stock_bulk.dart';
import 'package:mangopos/core/inventory/suggested_order.dart';

ProjectionLine _line(
  String id, {
  double consumption = 0,
  String unit = 'unidad',
  double suggestedMin = 0,
  String? sku,
  double stock = 0,
}) =>
    ProjectionLine(
      itemId: id,
      itemName: 'Insumo $id',
      sku: sku,
      unit: unit,
      consumption: consumption,
      dailyConsumption: consumption / 30,
      suggestedMinStock: suggestedMin,
      stock: stock,
    );

MinStockRow _row(
  String id, {
  double globalMin = 0,
  double? warehouseMin,
  String unit = 'unidad',
  double suggestedMin = 0,
  String? sku,
}) =>
    MinStockRow(
      line: _line(id, unit: unit, suggestedMin: suggestedMin, sku: sku),
      rotation: RotationClass.active,
      globalMin: globalMin,
      warehouseMin: warehouseMin,
    );

void main() {
  group('rotationClasses', () {
    test('igual que NTILE(10): 12 con consumo → 4 estrella, 3 activo, 5 lento', () {
      final lines = [
        for (var i = 1; i <= 12; i++) _line('i$i', consumption: 100.0 - i),
        _line('quieto'),
      ];
      final classes = rotationClasses(lines);
      expect(classes['quieto'], RotationClass.dormant);
      final counts = <RotationClass, int>{};
      for (final c in classes.values) {
        counts[c] = (counts[c] ?? 0) + 1;
      }
      expect(counts[RotationClass.star], 4);
      expect(counts[RotationClass.active], 3);
      expect(counts[RotationClass.slow], 5);
      expect(classes['i1'], RotationClass.star);
      expect(classes['i12'], RotationClass.slow);
    });

    test('con pocos insumos los primeros grupos se llenan primero', () {
      final classes = rotationClasses([
        _line('a', consumption: 9),
        _line('b', consumption: 5),
        _line('c', consumption: 1),
      ]);
      expect(classes, {
        'a': RotationClass.star,
        'b': RotationClass.star,
        'c': RotationClass.active,
      });
    });
  });

  group('roundMinStock', () {
    test('lo que se cuenta sube a entero; lo que se pesa, a centésimas', () {
      expect(roundMinStock(4.2, countable: true), 5);
      expect(roundMinStock(4.0000000001, countable: true), 4);
      expect(roundMinStock(4.201, countable: false), 4.21);
      expect(roundMinStock(-3, countable: true), 0);
    });

    test('el sugerido de la fila ya viene redondeado', () {
      expect(_row('a', suggestedMin: 7.3).suggestedMin, 8);
      expect(_row('b', unit: 'lb', suggestedMin: 7.301).suggestedMin, 7.31);
    });
  });

  group('bulkMinStock', () {
    final rows = [
      _row('latas', globalMin: 20, suggestedMin: 31.2),
      _row('queso', globalMin: 3, unit: 'lb', warehouseMin: 3, suggestedMin: 2.555),
    ];

    test('poner valor, aplicar sugerido y quitar', () {
      expect(bulkMinStock(rows: rows, action: MinStockBulkAction.setValue, value: 6),
          {'latas': 6, 'queso': 6});
      expect(bulkMinStock(rows: rows, action: MinStockBulkAction.applySuggested),
          {'latas': 32, 'queso': 2.56});
      expect(bulkMinStock(rows: rows, action: MinStockBulkAction.clear),
          {'latas': null, 'queso': null});
    });

    test('subir y bajar por porcentaje sobre el mínimo que rige', () {
      expect(bulkMinStock(rows: rows, action: MinStockBulkAction.adjustPercent, value: 10),
          {'latas': 22, 'queso': 3.3});
      expect(bulkMinStock(rows: rows, action: MinStockBulkAction.adjustPercent, value: -50),
          {'latas': 10, 'queso': 1.5});
    });
  });

  group('realMinStockChanges', () {
    final rows = {
      'con_propio': _row('con_propio', globalMin: 5, warehouseMin: 8),
      'sin_propio': _row('sin_propio', globalMin: 5),
      'general_cero': _row('general_cero'),
    };

    test('en un almacén: igual al propio o quitar lo que no existe no cuenta', () {
      final changes = realMinStockChanges(
        perWarehouse: true,
        rows: rows,
        pending: {'con_propio': 8, 'sin_propio': null, 'general_cero': 4},
      );
      expect(changes, {'general_cero': 4});
    });

    test('en un almacén: poner el mismo número que el general SÍ crea el propio', () {
      expect(
        realMinStockChanges(perWarehouse: true, rows: rows, pending: {'sin_propio': 5}),
        {'sin_propio': 5},
      );
    });

    test('en el negocio: quitar un general que ya es 0 no cuenta', () {
      final changes = realMinStockChanges(
        perWarehouse: false,
        rows: rows,
        pending: {'general_cero': null, 'sin_propio': null, 'con_propio': 5},
      );
      expect(changes, {'sin_propio': null});
    });
  });

  group('Excel de ida y vuelta', () {
    final rows = [
      MinStockRow(
        line: const ProjectionLine(
          itemId: 'id-1',
          itemName: 'Queso',
          sku: 'Q-01',
          unit: 'lb',
          classification: 'raw_material',
          stock: 12.5,
          dailyConsumption: 0.8333,
          suggestedMinStock: 4.1,
        ),
        rotation: RotationClass.star,
        globalMin: 3,
        maxStock: 30,
      ),
      _row('id-2', sku: 'lat-24'),
      _row('id-3', sku: 'DUP'),
      _row('id-4', sku: 'dup'),
    ];

    test('exporta las columnas en orden, con «Mínimo nuevo» vacío', () {
      final exported = buildMinStockExportRows(rows);
      expect(minStockExportHeaders.length, exported.first.length);
      expect(exported.first, [
        'id-1', 'Q-01', 'Queso', 'lb', 'Materia prima', 'Estrella',
        '12.5', '0.8333', '3', '4.1', '30', '',
      ]);
      expect(minStockExportNumericColumns.every((c) => c < minStockExportHeaders.length), isTrue);
    });

    test('importa por ID, por SKU, «quitar», coma decimal; salta vacíos y reporta errores', () {
      final table = <List<String?>>[
        ['Mínimos · Almacén Principal'],
        ['id', 'SKU', 'Insumo', 'Unidad', 'Clasificación', 'Rotación', 'Existencia',
         'Consumo diario', 'Mínimo actual', 'Mínimo sugerido', 'Máximo', 'MINIMO NUEVO'],
        ['id-1', 'Q-01', 'Queso', 'lb', '', '', '', '', '3', '4.1', '', '4,5'],
        ['', ' LAT-24 ', 'Latas', '', '', '', '', '', '', '', '', 'quitar'],
        ['id-9', '', 'Fantasma', '', '', '', '', '', '', '', '', '2'],
        ['', 'dup', 'Doble', '', '', '', '', '', '', '', '', '2'],
        ['id-1', '', 'Queso', '', '', '', '', '', '', '', '', '-1'],
        ['id-1', '', 'Queso', '', '', '', '', '', '', '', '', 'mucho'],
        ['id-2', '', 'Latas', '', '', '', '', '', '', '', '', ''],
        [null, null],
      ];
      final result = parseMinStockImport(table, rows);
      expect(result.changes, {'id-1': 4.5, 'id-2': null});
      expect(result.skipped, 1);
      expect(result.errors, [
        'Fila 5: no se encontró el insumo «Fantasma» (revisa que el archivo sea de este negocio).',
        'Fila 6: el SKU «dup» lo tienen varios insumos; usa la columna ID.',
        'Fila 7: el mínimo no puede ser negativo.',
        'Fila 8: «mucho» no es un número.',
      ]);
    });

    test('un archivo sin la columna «Mínimo nuevo» se rechaza con motivo', () {
      final result = parseMinStockImport([
        ['SKU', 'Mínimo'],
        ['Q-01', '4'],
      ], rows);
      expect(result.changes, isEmpty);
      expect(result.errors.single, contains('«Mínimo nuevo»'));
    });
  });
}
