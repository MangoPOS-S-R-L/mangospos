// Maestro de artículos de inventario — armado de la extracción.
//
// Lo que sale de acá es la ficha del insumo tal como la pide un contador o
// un auditor: código, descripción, código de barras y costo. Alrededor de
// esos cuatro va lo que hace que el archivo se pueda USAR sin volver a
// pedirle nada al sistema: la unidad en la que se cuenta, el empaque en el
// que se compra, la existencia (total y por bodega), el valor de esa
// existencia y los mínimos.
//
// Es una función PURA a propósito: la pantalla arma la lista, esto arma las
// filas y `ReportExporter` escribe el archivo. Así el orden de columnas y el
// cálculo del valor se pueden probar sin montar la vista.

import 'package:intl/intl.dart';

import '../state/inventory_state.dart';

/// Filas listas para exportar más los índices de las columnas que tienen que
/// llegar a Excel como número (cantidades) y como importe (2 decimales).
typedef InventoryMasterExportData = ({
  List<String> headers,
  List<List<String>> rows,
  List<int> numericColumns,
  List<int> moneyColumns,
});

class InventoryMasterExport {
  /// Cantidades sin separador de miles y con hasta 4 decimales: el archivo
  /// lo lee Excel, no una persona, y el formato visible lo pone la hoja.
  static String _qty(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value
        .toStringAsFixed(4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  static String _money(double value) => value.toStringAsFixed(2);

  static String _siNo(bool value) => value ? 'Sí' : 'No';

  static String classificationLabel(String value) => switch (value) {
    'raw_material' => 'Materia prima',
    'finished_product' => 'Producto terminado',
    'combo' => 'Combo',
    'service' => 'Servicio',
    _ => 'Simple',
  };

  static String costingLabel(String value) =>
      value == 'fifo' ? 'FIFO' : 'Promedio';

  /// Nombre de archivo con sello de fecha para que dos extracciones del
  /// mismo día no se pisen en la carpeta de descargas.
  static String filename({DateTime? now}) {
    final stamp = DateFormat('yyyyMMdd_HHmm').format(now ?? DateTime.now());
    return 'maestro_articulos_$stamp';
  }

  /// [items] son los insumos YA filtrados (lo que la pantalla muestra), y
  /// [warehouses] las bodegas visibles: cada una agrega su columna de
  /// existencia, en el mismo orden que la tabla.
  static InventoryMasterExportData build({
    required List<InventoryItemSummary> items,
    required List<InventoryWarehouse> warehouses,
    required InventoryStockMatrix matrix,
    String currencyCode = 'DOP',
  }) {
    final headers = <String>[
      // Los cuatro campos del pedido, primero y en ese orden.
      'Código',
      'Nombre',
      'Descripción',
      'Código de barras',
      'Costo unitario ($currencyCode)',
      // Sin la unidad, el costo y la existencia no significan nada: "12" es
      // doce mililitros o doce cajas según esta columna.
      'Unidad',
      'Unidad de compra',
      'Contenido por empaque',
      'Costo por empaque ($currencyCode)',
      'Existencia total',
      'Valor existencia ($currencyCode)',
      'Stock mínimo',
      'Stock máximo',
      for (final w in warehouses) 'Existencia · ${w.name}',
      'Clasificación',
      'Método de costeo',
      'Controla lotes',
      'Estado',
      // El ID va al final: no le sirve a quien lee el archivo, pero es lo
      // único que permite volver a casar la fila con el sistema en una
      // migración o una carga masiva.
      'ID interno',
    ];

    final rows = <List<String>>[];
    for (final item in items) {
      final stockRow = matrix.byWarehouse[item.id] ?? const <String, double>{};
      final packSize = item.packSize <= 0 ? 1.0 : item.packSize;
      rows.add(<String>[
        item.sku,
        item.name,
        item.description,
        item.barcode,
        _money(item.cost),
        item.unit,
        item.purchaseUnit,
        packSize == 1 ? '' : _qty(packSize),
        packSize == 1 ? '' : _money(item.cost * packSize),
        _qty(item.stock),
        _money(item.stock * item.cost),
        _qty(item.minStock),
        item.maxStock == null ? '' : _qty(item.maxStock!),
        for (final w in warehouses) _qty(stockRow[w.id] ?? 0),
        classificationLabel(item.itemClassification),
        costingLabel(item.costingMethod),
        _siNo(item.tracksLots),
        item.isActive ? 'Activo' : 'Inactivo',
        item.id,
      ]);
    }

    // Índices calculados y no escritos a mano: las columnas de bodega son
    // dinámicas y una constante quedaría desfasada con la primera bodega
    // nueva. El código de barras y el SKU quedan FUERA a propósito — como
    // número perderían los ceros a la izquierda.
    const firstWarehouseColumn = 13;
    final moneyColumns = <int>[
      4, // costo unitario
      8, // costo por empaque
      10, // valor existencia
    ];
    final numericColumns = <int>[
      7, // contenido por empaque
      9, // existencia total
      11, // mínimo
      12, // máximo
      for (var i = 0; i < warehouses.length; i++) firstWarehouseColumn + i,
    ];

    return (
      headers: headers,
      rows: rows,
      numericColumns: numericColumns,
      moneyColumns: moneyColumns,
    );
  }
}
