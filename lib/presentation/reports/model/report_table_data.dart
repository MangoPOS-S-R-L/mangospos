// Motor puro de la tabla personalizable: ordena, agrupa, calcula derivadas y
// totaliza según el tipo de cada columna. Lo consumen la pantalla Y los cinco
// exports, así que lo que se descarga es exactamente lo que se ve.

import 'report_column.dart';

class ReportCell {
  const ReportCell(this.raw, this.text);

  /// Celda en blanco (total de una columna no sumable).
  const ReportCell.blank()
      : raw = null,
        text = '';

  /// num | String | DateTime | null (sin dato).
  final Object? raw;
  final String text;
}

enum ReportTableRowType { data, groupHeader, subtotal }

class ReportTableRow {
  const ReportTableRow({
    required this.type,
    required this.cells,
    this.excluded = false,
    this.stripe = 0,
    this.groupLabel,
    this.groupSize = 0,
  });

  final ReportTableRowType type;

  /// Alineadas con [ReportTableData.columns]. Vacía en un encabezado de grupo.
  final List<ReportCell> cells;

  /// Anulado: se lista, no suma.
  final bool excluded;

  /// Índice de la fila de datos, para alternar el fondo.
  final int stripe;
  final String? groupLabel;
  final int groupSize;

  bool get isData => type == ReportTableRowType.data;
}

class ReportTableData {
  const ReportTableData({
    required this.definition,
    required this.config,
    required this.columns,
    required this.rows,
    required this.totals,
    required this.totalLabel,
    required this.labelColumnIndex,
    required this.dataRowCount,
    required this.validRowCount,
    required this.excludedRowCount,
    required this.excludedAmount,
  });

  final ReportDefinition definition;

  /// Configuración ya normalizada contra la definición.
  final ReportViewConfig config;

  /// Columnas visibles, en orden.
  final List<ReportColumn> columns;

  /// Filas de datos, encabezados de grupo y subtotales, en orden de pantalla.
  final List<ReportTableRow> rows;

  /// Fila de total, alineada con [columns].
  final List<ReportCell> totals;
  final String totalLabel;

  /// Columna donde van los rótulos "Total" / "Subtotal …".
  final int labelColumnIndex;
  final int dataRowCount;
  final int validRowCount;
  final int excludedRowCount;

  /// Σ del campo de participación de los excluidos (anulados).
  final double excludedAmount;

  bool get isEmpty => dataRowCount == 0;

  Iterable<ReportTableRow> get dataRows => rows.where((r) => r.isData);

  ReportColumn? get groupColumn => config.groupBy == null
      ? null
      : definition.column(config.groupBy!);
}

/// Lo que se exporta: la tabla tal como se ve más su contexto. Todos los
/// formatos parten de aquí, así que columnas, orden y total coinciden con la
/// pantalla.
class ReportTableExport {
  const ReportTableExport({
    required this.table,
    required this.title,
    required this.from,
    required this.to,
    required this.currencyCode,
    this.currencyDecimals = 2,
    this.notes = const [],
  });

  final ReportTableData table;
  final String title;

  /// Primer y último día incluidos.
  final DateTime from;
  final DateTime to;
  final String currencyCode;
  final int currencyDecimals;

  /// Notas al pie (anulados, filtros activos).
  final List<String> notes;

  String get rangeLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    String day(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year}';
    final sameDay =
        from.year == to.year && from.month == to.month && from.day == to.day;
    return sameDay ? day(from) : '${day(from)} – ${day(to)}';
  }

  /// `ventas_por_categoria_20260901_20260918`.
  String get fileStem {
    const accents = {
      'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ü': 'u', 'ñ': 'n',
    };
    final slug = title
        .toLowerCase()
        .split('')
        .map((c) => accents[c] ?? c)
        .join()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    String stamp(DateTime d) =>
        '${d.year}${d.month.toString().padLeft(2, '0')}'
        '${d.day.toString().padLeft(2, '0')}';
    return '${slug}_${stamp(from)}_${stamp(to)}';
  }
}

int _compareValues(Object? a, Object? b) {
  if (a is num && b is num) return a.compareTo(b);
  if (a is DateTime && b is DateTime) return a.compareTo(b);
  return a.toString().toLowerCase().compareTo(b.toString().toLowerCase());
}

/// Construye la tabla. [totalLabel] reemplaza el rótulo de la definición
/// (p. ej. "Total mostrado" en las vistas previas).
ReportTableData buildReportTable({
  required ReportDefinition definition,
  required List<ReportRecord> records,
  required ReportViewConfig config,
  required ReportFormats formats,
  String? totalLabel,
}) {
  final cfg = config.normalizedFor(definition);
  final columns = [
    for (final id in cfg.columns) definition.column(id)!,
  ];
  final shareField = definition.shareField;

  double shareOf(ReportRecord r) => r.number(shareField) ?? 0;

  var shareBase = 0.0;
  var excludedAmount = 0.0;
  var excludedCount = 0;
  for (final r in records) {
    if (r.excluded) {
      excludedCount++;
      excludedAmount += shareOf(r);
    } else {
      shareBase += shareOf(r);
    }
  }
  final baseContext = ReportValueContext(shareBase: shareBase);

  // 1. Orden. Estable: a igualdad, manda el orden de origen. Sin dato, al
  //    final siempre (en ambos sentidos).
  final order = List<int>.generate(records.length, (i) => i);
  final sortColumn =
      cfg.sortColumn == null ? null : definition.column(cfg.sortColumn!);
  if (sortColumn != null) {
    final keys = [for (final r in records) sortColumn.value(r, baseContext)];
    order.sort((a, b) {
      final ka = keys[a];
      final kb = keys[b];
      if (ka == null && kb == null) return a.compareTo(b);
      if (ka == null) return 1;
      if (kb == null) return -1;
      final cmp = _compareValues(ka, kb);
      if (cmp != 0) return cfg.sortAscending ? cmp : -cmp;
      return a.compareTo(b);
    });
  }

  // 2. Grupos, en orden de primera aparición (respeta el orden elegido).
  final groupColumn = cfg.groupBy == null ? null : definition.column(cfg.groupBy!);
  final groups = <String, List<int>>{};
  if (groupColumn != null) {
    for (final i in order) {
      final raw = groupColumn.value(records[i], baseContext);
      final key = formats.format(groupColumn.kind, raw);
      groups.putIfAbsent(key, () => <int>[]).add(i);
    }
  } else {
    groups[''] = order;
  }

  var labelIndex = columns.indexWhere((c) =>
      c.kind == ReportColumnKind.text && c.total == ReportColumnTotal.none);
  if (labelIndex < 0) labelIndex = 0;

  // 3. Filas con posición y acumulado corridos sobre el orden final.
  final rows = <ReportTableRow>[];
  var position = 0;
  var cumulative = 0.0;
  var stripe = 0;
  for (final entry in groups.entries) {
    final members = entry.value;
    if (groupColumn != null) {
      rows.add(ReportTableRow(
        type: ReportTableRowType.groupHeader,
        cells: const [],
        groupLabel: '${groupColumn.label}: ${entry.key}',
        groupSize: members.length,
      ));
    }
    final memberCells = <List<ReportCell>>[];
    final memberRecords = <ReportRecord>[];
    for (final i in members) {
      final record = records[i];
      position++;
      if (!record.excluded) cumulative += shareOf(record);
      final context = ReportValueContext(
        shareBase: shareBase,
        position: position,
        cumulative: cumulative,
      );
      final cells = [
        for (final column in columns)
          () {
            final raw = column.value(record, context);
            return ReportCell(raw, formats.format(column.kind, raw));
          }(),
      ];
      memberCells.add(cells);
      memberRecords.add(record);
      rows.add(ReportTableRow(
        type: ReportTableRowType.data,
        cells: cells,
        excluded: record.excluded,
        stripe: stripe++,
      ));
    }
    if (groupColumn != null) {
      final subtotal = _aggregate(
        columns: columns,
        records: memberRecords,
        cells: memberCells,
        formats: formats,
        grandTotal: false,
      );
      subtotal[labelIndex] = ReportCell(
          'Subtotal ${entry.key}', 'Subtotal ${entry.key}');
      rows.add(ReportTableRow(
        type: ReportTableRowType.subtotal,
        cells: subtotal,
        groupLabel: entry.key,
        groupSize: members.length,
      ));
    }
  }

  final allCells = [
    for (final row in rows)
      if (row.isData) row.cells,
  ];
  final orderedRecords = [
    for (final group in groups.values)
      for (final i in group) records[i],
  ];
  final validCount = records.length - excludedCount;
  final label = totalLabel ?? definition.totalLabel(validCount);
  final totals = _aggregate(
    columns: columns,
    records: orderedRecords,
    cells: allCells,
    formats: formats,
    grandTotal: true,
  );
  if (columns.isNotEmpty) totals[labelIndex] = ReportCell(label, label);

  return ReportTableData(
    definition: definition,
    config: cfg,
    columns: List.unmodifiable(columns),
    rows: List.unmodifiable(rows),
    totals: List.unmodifiable(totals),
    totalLabel: label,
    labelColumnIndex: labelIndex,
    dataRowCount: records.length,
    validRowCount: validCount,
    excludedRowCount: excludedCount,
    excludedAmount: excludedAmount,
  );
}

/// Total (o subtotal) por tipo de columna, solo sobre las filas válidas.
List<ReportCell> _aggregate({
  required List<ReportColumn> columns,
  required List<ReportRecord> records,
  required List<List<ReportCell>> cells,
  required ReportFormats formats,
  required bool grandTotal,
}) {
  final out = <ReportCell>[];
  // 100.0 % solo si alguna fila válida tiene participación (con base cero
  // las filas van en guion y el total no puede afirmar un 100 %).
  ReportCell fullShare(int c, ReportColumn column) {
    for (var i = 0; i < records.length; i++) {
      if (!records[i].excluded && cells[i][c].raw != null) {
        return ReportCell(100.0, formats.format(column.kind, 100.0));
      }
    }
    return const ReportCell.blank();
  }

  for (var c = 0; c < columns.length; c++) {
    final column = columns[c];
    switch (column.total) {
      case ReportColumnTotal.sum:
      case ReportColumnTotal.share:
        if (column.total == ReportColumnTotal.share && grandTotal) {
          out.add(fullShare(c, column));
          break;
        }
        double? sum;
        for (var i = 0; i < records.length; i++) {
          if (records[i].excluded) continue;
          final raw = cells[i][c].raw;
          if (raw is num) sum = (sum ?? 0) + raw;
        }
        out.add(ReportCell(sum, formats.format(column.kind, sum)));
      case ReportColumnTotal.weighted:
        final ratio = column.ratioOf;
        if (ratio == null) {
          out.add(const ReportCell.blank());
          break;
        }
        var numerator = 0.0;
        var denominator = 0.0;
        for (final r in records) {
          if (r.excluded) continue;
          numerator += r.number(ratio.numerator) ?? 0;
          denominator += r.number(ratio.denominator) ?? 0;
        }
        final value =
            denominator > 0 ? numerator / denominator * 100 : null;
        out.add(ReportCell(value, formats.format(column.kind, value)));
      case ReportColumnTotal.cumulativeShare:
        out.add(grandTotal ? fullShare(c, column) : const ReportCell.blank());
      case ReportColumnTotal.none:
        out.add(const ReportCell.blank());
    }
  }
  return out;
}
