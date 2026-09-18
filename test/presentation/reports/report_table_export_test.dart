// Los cinco formatos del botón Exportar descargan exactamente las columnas
// visibles, en su orden, con el orden de filas y la fila de total de la
// pantalla (criterio de aceptación 7).

import 'dart:convert';

import 'package:excel/excel.dart' as xlsx;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/presentation/reports/model/report_column.dart';
import 'package:mangopos/presentation/reports/model/report_table_data.dart';
import 'package:mangopos/presentation/reports/services/reports_csv_export_service.dart';
import 'package:mangopos/presentation/reports/services/reports_export_service.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';

ReportTableExport _export() {
  final definition = ReportCatalog.breakdown(
    key: 'sales.byCategory',
    title: 'Ventas por categoría',
    source: 'getCategoryRows()',
    labels: const BreakdownLabels(
      axis: 'Categoría',
      count: 'Tickets',
      amount: 'Ventas',
      unit: 'ticket',
      showQuantity: true,
    ),
  );
  final records = [
    const SalesBreakdownRow(
        label: 'Bebidas', amount: 1250000.5, count: 40, quantity: 120),
    const SalesBreakdownRow(
        label: 'Comida', amount: 8749999.49, count: 60, quantity: 75.5),
  ]
      .map((r) => ReportCatalog.breakdownRecord(r, showQuantity: true))
      .toList();
  // Orden de columnas distinto al por defecto y filas ordenadas por monto.
  const config = ReportViewConfig(
    columns: [
      ReportColumnIds.amount,
      ReportColumnIds.label,
      ReportColumnIds.share,
      ReportColumnIds.amountPerCount,
    ],
    sortColumn: ReportColumnIds.amount,
  );
  final table = buildReportTable(
    definition: definition,
    records: records,
    config: config,
    formats: ReportFormats(
      currency: NumberFormat.currency(symbol: r'RD$', decimalDigits: 2),
    ),
  );
  return ReportTableExport(
    table: table,
    title: 'Ventas por categoría',
    from: DateTime(2026, 9, 1),
    to: DateTime(2026, 9, 18),
    currencyCode: 'DOP',
  );
}

void main() {
  late ReportTableExport export;

  setUp(() => export = _export());

  test('nombre de archivo sin acentos, con el rango', () {
    expect(export.fileStem, 'ventas_por_categoria_20260901_20260918');
  });

  test('CSV: columnas visibles en su orden, filas ordenadas y total', () {
    final lines = ReportsCsvExportService.buildTableCsv(export).split('\n');
    expect(lines.first,
        '"Ventas","Categoría","% del total","Ventas por ticket"');
    expect(lines[1], startsWith('"8749999.49","Comida",'));
    expect(lines[2], startsWith('"1250000.50","Bebidas",'));
    // Total: suma, rótulo, 100 % y la tasa en blanco.
    expect(lines.last, '"9999999.99","Total","100.00",""');
  });

  test('TXT: ancho fijo, cifras alineadas a la derecha', () {
    final txt = ReportsExportService.buildTableTxt(export);
    final lines = txt.split('\n');
    // Título, rango, generado, línea en blanco y luego el encabezado.
    final headerLine = lines[4];
    expect(headerLine, contains('Categoría'));
    final comida = lines.firstWhere((l) => l.contains('Comida'));
    final total =
        lines.lastWhere((l) => l.contains('Total') && l.contains('RD'));
    // La columna de monto termina en la misma posición en todas las filas.
    final end = headerLine.indexOf('Ventas') + 'Ventas'.length;
    expect(comida.substring(0, end).trimLeft(), r'RD$8,749,999.49');
    expect(total.substring(0, end).trimLeft(), r'RD$9,999,999.99');
    expect(txt, contains('Rango: 01/09/2026 – 18/09/2026'));
  });

  test('JSON: filas por id de columna, con catálogo y total', () {
    final json =
        jsonDecode(ReportsExportService.buildTableJson(export)) as Map;
    expect((json['columns'] as List).map((c) => c['id']).toList(), [
      ReportColumnIds.amount,
      ReportColumnIds.label,
      ReportColumnIds.share,
      ReportColumnIds.amountPerCount,
    ]);
    final rows = json['rows'] as List;
    expect(rows.first['label'], 'Comida');
    expect(rows.first['amount'], 8749999.49);
    expect(json['total']['values']['amount'], closeTo(9999999.99, 1e-6));
    expect(json['total']['values']['amount_per_count'], isNull);
    expect(json['range'], {'from': '2026-09-01', 'to': '2026-09-18'});
    expect(json['source'], 'getCategoryRows()');
  });

  test('Excel: encabezados en orden, cifras como número y fila de total', () {
    final bytes = ReportsExportService.buildTableXlsx(export);
    expect(bytes, isNotNull);
    final book = xlsx.Excel.decodeBytes(bytes!);
    final sheet = book.tables.values.first;
    xlsx.CellValue? cell(int c, int r) => sheet
        .cell(xlsx.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r))
        .value;

    expect(cell(0, 3).toString(), 'Ventas');
    expect(cell(1, 3).toString(), 'Categoría');
    expect(cell(0, 4), isA<xlsx.DoubleCellValue>());
    expect((cell(0, 4) as xlsx.DoubleCellValue).value, 8749999.49);
    // Participación como fracción con formato de porcentaje.
    expect((cell(2, 4) as xlsx.DoubleCellValue).value,
        closeTo(0.874999948, 1e-6));
    // Fila de total al pie (encabezado en fila 3, dos filas de datos).
    expect(cell(1, 6).toString(), 'Total');
    expect((cell(0, 6) as xlsx.DoubleCellValue).value,
        closeTo(9999999.99, 1e-6));
  });

  test('PDF: se genera', () async {
    final bytes = await ReportsExportService.buildTablePdf(export);
    expect(bytes.length, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('PDF: euro y nombres fuera de Latin-1 no rompen el export', () async {
    final definition = ReportCatalog.breakdown(
      key: 'sales.byEmployee',
      title: 'Ventas por empleado',
      source: 'getEmployeeRows()',
      labels: const BreakdownLabels(
        axis: 'Empleado',
        count: 'Órdenes',
        amount: 'Ventas',
        unit: 'orden',
        showQuantity: false,
      ),
    );
    final table = buildReportTable(
      definition: definition,
      records: [
        ReportCatalog.breakdownRecord(
          const SalesBreakdownRow(label: 'Šimon 🍕', amount: 1234.5, count: 3),
          showQuantity: false,
        ),
      ],
      config: definition.defaultConfig,
      formats: ReportFormats(
        currency:
            NumberFormat.currency(symbol: '€', decimalDigits: 2, locale: 'de'),
      ),
    );
    final bytes = await ReportsExportService.buildTablePdf(ReportTableExport(
      table: table,
      title: 'Ventas por empleado',
      from: DateTime(2026, 9, 1),
      to: DateTime(2026, 9, 1),
      currencyCode: 'EUR',
    ));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });
}
