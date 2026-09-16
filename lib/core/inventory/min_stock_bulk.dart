/// Mínimos en lote (Compras F3).
///
/// La pantalla carga la proyección (`fn_purchase_projection`), que ya trae el
/// consumo real y el MÍNIMO SUGERIDO (consumo diario × (entrega + días de
/// colchón)), y deja cambiar el mínimo de cientos de insumos de una vez. Aquí
/// va lo que no necesita la base: la rotación, las acciones sobre la
/// selección, qué de lo tocado cambia de verdad, y el Excel de ida y vuelta.
///
/// Funciones puras.
library;

import 'suggested_order.dart';

const double _eps = 1e-9;

/// Rotación del insumo, con la misma regla que `fn_inventory_rotation_analysis`
/// (20260514_0010), pero con el consumo de la proyección (sin transferencias ni
/// ajustes, B6).
enum RotationClass { star, active, slow, dormant }

extension RotationClassLabel on RotationClass {
  String get label => switch (this) {
        RotationClass.star => 'Estrella',
        RotationClass.active => 'Activo',
        RotationClass.slow => 'Lento',
        RotationClass.dormant => 'Dormido',
      };
}

/// Los que se consumieron se reparten en 10 grupos por consumo, como NTILE(10)
/// de Postgres (los primeros grupos se llevan el sobrante): 1–2 estrella,
/// 3–5 activo, 6–10 lento. Sin consumo en la ventana: dormido.
Map<String, RotationClass> rotationClasses(Iterable<ProjectionLine> lines) {
  final result = <String, RotationClass>{};
  final moving = <ProjectionLine>[];
  for (final line in lines) {
    if (line.consumption > _eps) {
      moving.add(line);
    } else {
      result[line.itemId] = RotationClass.dormant;
    }
  }
  moving.sort((a, b) {
    final byConsumption = b.consumption.compareTo(a.consumption);
    return byConsumption != 0 ? byConsumption : a.itemId.compareTo(b.itemId);
  });

  final n = moving.length;
  final base = n ~/ 10;
  final extra = n % 10;
  var index = 0;
  for (var bucket = 1; bucket <= 10 && index < n; bucket++) {
    final size = base + (bucket <= extra ? 1 : 0);
    for (var k = 0; k < size && index < n; k++) {
      result[moving[index++].itemId] = bucket <= 2
          ? RotationClass.star
          : bucket <= 5
              ? RotationClass.active
              : RotationClass.slow;
    }
  }
  return result;
}

/// Un mínimo que se puede guardar: entero hacia arriba si la unidad se cuenta
/// (no hay 4.2 latas), a centésimas hacia arriba si se pesa o se mide.
double roundMinStock(double value, {required bool countable}) {
  if (value <= _eps) return 0;
  if (countable) return (value - _eps).ceilToDouble();
  return ((value * 100) - _eps).ceilToDouble() / 100;
}

/// Una fila de la pantalla.
class MinStockRow {
  final ProjectionLine line;
  final RotationClass rotation;

  /// Mínimo general del insumo (`inventory_items.min_stock`).
  final double globalMin;

  /// Mínimo propio del almacén (`inventory_stock.min_stock`). Null: usa el
  /// general. Siempre null cuando se edita el negocio completo.
  final double? warehouseMin;
  final double? maxStock;

  const MinStockRow({
    required this.line,
    required this.rotation,
    required this.globalMin,
    this.warehouseMin,
    this.maxStock,
  });

  String get itemId => line.itemId;

  /// El mínimo que rige hoy.
  double get currentMin => warehouseMin ?? globalMin;

  /// Lo que sugiere el consumo, ya redondeado a algo guardable.
  double get suggestedMin =>
      roundMinStock(line.suggestedMinStock, countable: line.baseIsCountable);
}

enum MinStockBulkAction { setValue, applySuggested, adjustPercent, clear }

/// Valores nuevos para [rows]. `null` = quitar: en un almacén vuelve a regir
/// el general; en el negocio el mínimo queda en 0.
Map<String, double?> bulkMinStock({
  required Iterable<MinStockRow> rows,
  required MinStockBulkAction action,
  double value = 0,
}) {
  return {
    for (final r in rows)
      r.itemId: switch (action) {
        MinStockBulkAction.setValue => value < 0 ? 0.0 : value,
        MinStockBulkAction.applySuggested => r.suggestedMin,
        MinStockBulkAction.adjustPercent => roundMinStock(
            r.currentMin * (1 + value / 100),
            countable: r.line.baseIsCountable,
          ),
        MinStockBulkAction.clear => null,
      },
  };
}

bool _same(double? a, double? b) {
  if (a == null || b == null) return a == b;
  return (a - b).abs() < _eps;
}

/// Solo lo que de verdad cambia. Tocar una fila y dejarla igual no manda nada
/// a la base ni cuenta en «Guardar N cambios».
Map<String, double?> realMinStockChanges({
  required Map<String, double?> pending,
  required Map<String, MinStockRow> rows,
  required bool perWarehouse,
}) {
  final result = <String, double?>{};
  pending.forEach((itemId, value) {
    final row = rows[itemId];
    if (row == null) return;
    final unchanged = perWarehouse
        ? _same(row.warehouseMin, value)
        : _same(row.globalMin, value ?? 0);
    if (!unchanged) result[itemId] = value;
  });
  return result;
}

// ---------------------------------------------------------------------------
// Excel de ida y vuelta
// ---------------------------------------------------------------------------

const minStockExportHeaders = [
  'ID',
  'SKU',
  'Insumo',
  'Unidad',
  'Clasificación',
  'Rotación',
  'Existencia',
  'Consumo diario',
  'Mínimo actual',
  'Mínimo sugerido',
  'Máximo',
  'Mínimo nuevo',
];

/// Columnas que llegan a Excel como número.
const minStockExportNumericColumns = [6, 7, 8, 9, 10, 11];

String _classificationLabel(String value) => switch (value) {
      'raw_material' => 'Materia prima',
      'finished_product' => 'Producto terminado',
      'combo' => 'Combo',
      'service' => 'Servicio',
      _ => 'Simple',
    };

String _qty(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// Filas para `ReportExporter.exportExcel`. «Mínimo nuevo» va vacío: se llena
/// en Excel y se vuelve a subir con [parseMinStockImport].
List<List<String>> buildMinStockExportRows(Iterable<MinStockRow> rows) {
  return [
    for (final r in rows)
      [
        r.itemId,
        r.line.sku ?? '',
        r.line.itemName,
        r.line.unit,
        _classificationLabel(r.line.classification),
        r.rotation.label,
        _qty(r.line.stock),
        _qty(r.line.dailyConsumption),
        _qty(r.currentMin),
        _qty(r.suggestedMin),
        r.maxStock == null ? '' : _qty(r.maxStock!),
        '',
      ],
  ];
}

class MinStockImportResult {
  /// itemId → mínimo nuevo (null = quitar).
  final Map<String, double?> changes;

  /// «Fila 12: …», en el orden del archivo.
  final List<String> errors;

  /// Filas con «Mínimo nuevo» vacío.
  final int skipped;

  const MinStockImportResult({
    required this.changes,
    required this.errors,
    required this.skipped,
  });
}

String _norm(String? value) {
  const from = 'áéíóúüñÁÉÍÓÚÜÑ';
  const to = 'aeiouunAEIOUUN';
  final buffer = StringBuffer();
  for (final ch in (value ?? '').trim().toLowerCase().split('')) {
    final i = from.indexOf(ch);
    buffer.write(i >= 0 ? to[i].toLowerCase() : ch);
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ');
}

/// Número como lo escribe una persona o lo entrega Excel: «5», «5.0»,
/// «2,5», «1,234.5». Null si no es número.
double? _parseNumber(String raw) {
  var s = raw.trim().replaceAll(' ', '');
  if (s.isEmpty) return null;
  if (s.contains(',') && s.contains('.')) {
    s = s.replaceAll(',', '');
  } else {
    s = s.replaceAll(',', '.');
  }
  return double.tryParse(s);
}

const _clearWords = {'quitar', 'borrar', 'sin minimo', '-'};

/// Lee el Excel devuelto: busca la fila de encabezados (la que tiene «Mínimo
/// nuevo»), identifica cada insumo por ID y, si no, por SKU, y toma solo las
/// filas con «Mínimo nuevo» escrito. «quitar» borra el mínimo.
MinStockImportResult parseMinStockImport(
  List<List<String?>> table,
  Iterable<MinStockRow> rows,
) {
  final byId = {for (final r in rows) r.itemId: r};
  final skuCount = <String, int>{};
  final bySku = <String, MinStockRow>{};
  for (final r in rows) {
    final sku = _norm(r.line.sku);
    if (sku.isEmpty) continue;
    skuCount[sku] = (skuCount[sku] ?? 0) + 1;
    bySku[sku] = r;
  }

  var headerIndex = -1;
  var idCol = -1, skuCol = -1, nameCol = -1, newCol = -1;
  for (var i = 0; i < table.length && headerIndex < 0; i++) {
    final cells = table[i].map(_norm).toList();
    final n = cells.indexOf('minimo nuevo');
    if (n < 0) continue;
    headerIndex = i;
    newCol = n;
    idCol = cells.indexOf('id');
    skuCol = cells.indexOf('sku');
    nameCol = cells.indexOf('insumo');
  }
  if (headerIndex < 0) {
    return const MinStockImportResult(
      changes: {},
      errors: ['El archivo no tiene la columna «Mínimo nuevo». Exporta primero desde esta pantalla.'],
      skipped: 0,
    );
  }

  String? cell(List<String?> row, int col) =>
      col >= 0 && col < row.length ? row[col] : null;

  final changes = <String, double?>{};
  final errors = <String>[];
  final seenAt = <String, int>{};
  var skipped = 0;

  for (var i = headerIndex + 1; i < table.length; i++) {
    final row = table[i];
    final fileRow = i + 1;
    final rawNew = (cell(row, newCol) ?? '').trim();
    if (row.every((c) => (c ?? '').trim().isEmpty)) continue;
    if (rawNew.isEmpty) {
      skipped++;
      continue;
    }

    final id = (cell(row, idCol) ?? '').trim();
    final sku = _norm(cell(row, skuCol));
    final label = [
      (cell(row, nameCol) ?? '').trim(),
      if (sku.isNotEmpty) sku,
    ].where((s) => s.isNotEmpty).join(' · ');

    MinStockRow? match = byId[id];
    if (match == null && sku.isNotEmpty) {
      if ((skuCount[sku] ?? 0) > 1) {
        errors.add('Fila $fileRow: el SKU «$sku» lo tienen varios insumos; usa la columna ID.');
        continue;
      }
      match = bySku[sku];
    }
    if (match == null) {
      errors.add('Fila $fileRow: no se encontró el insumo${label.isEmpty ? '' : ' «$label»'} '
          '(revisa que el archivo sea de este negocio).');
      continue;
    }

    final double? value;
    if (_clearWords.contains(_norm(rawNew))) {
      value = null;
    } else {
      final parsed = _parseNumber(rawNew);
      if (parsed == null) {
        errors.add('Fila $fileRow: «$rawNew» no es un número.');
        continue;
      }
      if (parsed < 0) {
        errors.add('Fila $fileRow: el mínimo no puede ser negativo.');
        continue;
      }
      value = parsed;
    }

    final previous = seenAt[match.itemId];
    if (previous != null) {
      errors.add('Fila $fileRow: ${match.line.itemName} ya venía en la fila $previous; se usa la última.');
    }
    seenAt[match.itemId] = fileRow;
    changes[match.itemId] = value;
  }

  return MinStockImportResult(changes: changes, errors: errors, skipped: skipped);
}
