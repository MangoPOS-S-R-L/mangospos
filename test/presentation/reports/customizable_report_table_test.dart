// Criterio 4: ningún encabezado ni ninguna cifra aparecen cortados, en
// densidad cómoda ni compacta, con totales de siete dígitos y centavos.
//
// Se carga la Roboto Mono real de la app: la fuente de pruebas por defecto
// mide 1 em por caracter y daría falsos cortes.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/presentation/reports/model/report_column.dart';
import 'package:mangopos/presentation/reports/model/report_table_data.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/customizable_report_table.dart';

Future<void> _loadMonoFont() async {
  ByteData read(String path) =>
      ByteData.sublistView(File(path).readAsBytesSync());
  final loader = FontLoader(reportNumberFontFamily)
    ..addFont(Future.value(read('assets/fonts/RobotoMono-Regular.ttf')))
    ..addFont(Future.value(read('assets/fonts/RobotoMono-Bold.ttf')));
  await loader.load();
}

final _currency = NumberFormat.currency(symbol: r'RD$', decimalDigits: 2);

ReportTableData _table({required bool showQuantity}) {
  final definition = ReportCatalog.breakdown(
    key: 'sales.byHour',
    title: 'Ventas por hora',
    source: 'getHourlyRows()',
    labels: BreakdownLabels(
      axis: 'Franja horaria',
      count: 'Transacciones',
      amount: 'Ventas',
      unit: 'transacción',
      showQuantity: showQuantity,
    ),
  );
  return buildReportTable(
    definition: definition,
    records: [
      for (final row in const [
        SalesBreakdownRow(
            label: '12:00', amount: 4999999.99, count: 1234, quantity: 3456),
        SalesBreakdownRow(
            label: '13:00', amount: 4999999.99, count: 4321, quantity: 6543),
      ])
        ReportCatalog.breakdownRecord(row, showQuantity: showQuantity),
    ],
    // Completa: todas las columnas, incluidos los rótulos largos.
    config: definition.preset('full')!.config,
    formats: ReportFormats(currency: _currency),
  );
}

Future<void> _pump(
  WidgetTester tester,
  ReportTableData table,
  ReportDensity density,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 1280,
            child: CustomizableReportTable(table: table, density: density),
          ),
        ),
      ),
    ),
  );
}

/// El texto cabe en el espacio que le dio su celda.
void _expectFits(WidgetTester tester, String text) {
  final finder = find.text(text);
  expect(finder, findsWidgets, reason: 'no se pintó "$text"');
  for (final element in finder.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    final natural = paragraph.getMaxIntrinsicWidth(double.infinity);
    expect(
      natural,
      lessThanOrEqualTo(paragraph.size.width + 0.5),
      reason: '"$text" necesita ${natural.toStringAsFixed(1)} px y su celda '
          'le da ${paragraph.size.width.toStringAsFixed(1)} px',
    );
  }
}

void main() {
  setUpAll(_loadMonoFont);

  for (final density in ReportDensity.values) {
    testWidgets('sin cortes en densidad ${density.name}', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final table = _table(showQuantity: true);
      await _pump(tester, table, density);

      for (final column in table.columns) {
        _expectFits(tester, column.label);
      }
      // Total de siete dígitos con centavos.
      _expectFits(tester, r'RD$9,999,999.98');
      _expectFits(tester, r'RD$4,999,999.99');
      _expectFits(tester, '100.0 %');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('sin cantidad: guion en cantidad y derivadas', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final table = _table(showQuantity: false);
    await _pump(tester, table, ReportDensity.comfortable);

    // Por fila: cantidad, precio por unidad y cantidad por transacción.
    // Más el total de cantidad, que tampoco existe.
    expect(find.text(ReportFormats.missing), findsNWidgets(2 * 3 + 1));
  });

  test('una moneda nunca por debajo de 172 px', () {
    final table = _table(showQuantity: true);
    final widths = computeReportColumnWidths(
      table: table,
      metrics: ReportTableMetrics.compact,
      baseStyle: const TextStyle(),
    );
    for (var c = 0; c < table.columns.length; c++) {
      if (table.columns[c].kind == ReportColumnKind.money) {
        expect(widths[c], greaterThanOrEqualTo(172));
      }
    }
  });
}
