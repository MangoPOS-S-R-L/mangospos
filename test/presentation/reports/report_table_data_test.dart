// Reglas de la tabla personalizable (spec "Reportes personalizables" §6):
// totales por tipo de columna, guion donde el dato no existe, anulados que
// se listan pero no suman, agrupación con subtotales y orden estable.

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/presentation/reports/model/report_column.dart';
import 'package:mangopos/presentation/reports/model/report_table_data.dart';
import 'package:mangopos/presentation/reports/state/report_view_preferences.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';

final _formats = ReportFormats(
  currency: NumberFormat.currency(symbol: r'RD$', decimalDigits: 2),
);

const _employeeLabels = BreakdownLabels(
  axis: 'Empleado',
  count: 'Órdenes',
  amount: 'Ventas',
  unit: 'orden',
  showQuantity: false,
);

const _categoryLabels = BreakdownLabels(
  axis: 'Categoría',
  count: 'Tickets',
  amount: 'Ventas',
  unit: 'ticket',
  showQuantity: true,
);

ReportDefinition _breakdown(BreakdownLabels labels) => ReportCatalog.breakdown(
      key: 'sales.test',
      title: 'Prueba',
      source: 'getTestRows()',
      labels: labels,
    );

List<ReportRecord> _records(
  List<SalesBreakdownRow> rows, {
  required bool showQuantity,
}) =>
    [
      for (final row in rows)
        ReportCatalog.breakdownRecord(row, showQuantity: showQuantity),
    ];

ReportTableData _build(
  ReportDefinition definition,
  List<ReportRecord> records,
  ReportViewConfig config,
) =>
    buildReportTable(
      definition: definition,
      records: records,
      config: config,
      formats: _formats,
    );

int _col(ReportTableData table, String id) =>
    table.columns.indexWhere((c) => c.id == id);

ProductSalesReportRow _product(
  String name,
  String category, {
  required double net,
  required double cost,
  double discounts = 0,
}) =>
    ProductSalesReportRow(
      productId: name,
      product: name,
      category: category,
      quantitySold: 1,
      projectedQuantity: 0,
      grossSales: net + discounts,
      discounts: discounts,
      courtesies: 0,
      netSales: net,
      cost: cost,
      grossProfit: net - cost,
      marginPct: net > 0 ? (net - cost) / net * 100 : null,
      tickets: 1,
    );

void main() {
  group('desglose (SalesBreakdownRow)', () {
    final employees = [
      const SalesBreakdownRow(label: 'Ana', amount: 3000, count: 10),
      const SalesBreakdownRow(label: 'Luis', amount: 1000, count: 5),
    ];

    test('abre con sus columnas de siempre', () {
      final definition = _breakdown(_employeeLabels);
      final table = _build(
        definition,
        _records(employees, showQuantity: false),
        definition.defaultConfig,
      );
      expect(table.columns.map((c) => c.label).toList(),
          ['Empleado', 'Cantidad', 'Órdenes', 'Ventas']);
    });

    test('sin cantidad: guion en la celda y en sus derivadas, no cero', () {
      final definition = _breakdown(_employeeLabels);
      final table = _build(
        definition,
        _records(employees, showQuantity: false),
        const ReportViewConfig(columns: [
          ReportColumnIds.label,
          ReportColumnIds.quantity,
          ReportColumnIds.amountPerUnit,
          ReportColumnIds.quantityPerCount,
        ]),
      );
      for (final row in table.dataRows) {
        expect(row.cells[1].text, ReportFormats.missing);
        expect(row.cells[2].text, ReportFormats.missing);
        expect(row.cells[3].text, ReportFormats.missing);
      }
      expect(table.totals[_col(table, ReportColumnIds.quantity)].text,
          ReportFormats.missing);
    });

    test('suma monto y conteo; tasas y # en blanco en el total', () {
      final definition = _breakdown(_employeeLabels);
      final table = _build(
        definition,
        _records(employees, showQuantity: false),
        const ReportViewConfig(columns: [
          ReportColumnIds.position,
          ReportColumnIds.label,
          ReportColumnIds.count,
          ReportColumnIds.amount,
          ReportColumnIds.amountPerCount,
          ReportColumnIds.cumulative,
        ]),
      );
      expect(table.totals[_col(table, ReportColumnIds.amount)].raw, 4000);
      expect(table.totals[_col(table, ReportColumnIds.count)].raw, 15);
      expect(table.totals[_col(table, ReportColumnIds.amountPerCount)].text,
          '');
      expect(table.totals[_col(table, ReportColumnIds.position)].text, '');
      expect(table.totals[_col(table, ReportColumnIds.cumulative)].text, '');
      // El rótulo va en la primera columna de texto, no en `#`.
      expect(table.totals[_col(table, ReportColumnIds.label)].text, 'Total');
    });

    test('participación y % acumulado: 100.0 % en el total', () {
      final definition = _breakdown(_employeeLabels);
      final pareto = definition.preset('pareto')!.config;
      final table = _build(
        definition,
        _records(
          [
            const SalesBreakdownRow(label: 'Luis', amount: 1000, count: 5),
            const SalesBreakdownRow(label: 'Ana', amount: 3000, count: 10),
          ],
          showQuantity: false,
        ),
        pareto,
      );
      // Pareto ordena por monto de mayor a menor.
      final rows = table.dataRows.toList();
      expect(rows.first.cells[_col(table, ReportColumnIds.label)].text, 'Ana');
      expect(rows.first.cells[_col(table, ReportColumnIds.position)].raw, 1);
      expect(rows.first.cells[_col(table, ReportColumnIds.share)].text,
          '75.0 %');
      expect(rows.last.cells[_col(table, ReportColumnIds.cumulative)].raw,
          4000);
      expect(
          rows.last.cells[_col(table, ReportColumnIds.cumulativeShare)].text,
          '100.0 %');
      expect(table.totals[_col(table, ReportColumnIds.share)].text, '100.0 %');
      expect(table.totals[_col(table, ReportColumnIds.cumulativeShare)].text,
          '100.0 %');
    });

    test('monto por movimiento y rótulo compuesto por unidad', () {
      final definition = _breakdown(_categoryLabels);
      final column = definition.column(ReportColumnIds.amountPerCount)!;
      expect(column.label, 'Ventas por ticket');
      expect(definition.column(ReportColumnIds.quantityPerCount)!.label,
          'Cantidad por ticket');
      final table = _build(
        definition,
        _records(
          [
            const SalesBreakdownRow(
                label: 'Bebidas', amount: 900, count: 3, quantity: 12),
          ],
          showQuantity: true,
        ),
        const ReportViewConfig(columns: [
          ReportColumnIds.label,
          ReportColumnIds.amountPerCount,
          ReportColumnIds.amountPerUnit,
          ReportColumnIds.quantityPerCount,
        ]),
      );
      final row = table.dataRows.single;
      expect(row.cells[1].raw, 300);
      expect(row.cells[2].raw, 75);
      expect(row.cells[3].raw, 4);
    });

    test('orden: numéricas, estable y sin dato al final', () {
      final definition = _breakdown(_categoryLabels);
      final table = _build(
        definition,
        _records(
          [
            const SalesBreakdownRow(label: 'A', amount: 10, count: 0),
            const SalesBreakdownRow(label: 'B', amount: 50, count: 2),
            const SalesBreakdownRow(label: 'C', amount: 50, count: 1),
          ],
          showQuantity: true,
        ),
        const ReportViewConfig(
          columns: [
            ReportColumnIds.label,
            ReportColumnIds.amount,
            ReportColumnIds.amountPerCount,
          ],
          sortColumn: ReportColumnIds.amountPerCount,
        ),
      );
      // B=25, C=50, A=sin dato (count 0). Desc: C, B, A.
      expect(
        table.dataRows.map((r) => r.cells[0].text).toList(),
        ['C', 'B', 'A'],
      );
    });
  });

  group('ventas por producto', () {
    final definition = ReportCatalog.productSales();
    final records = [
      _product('Mojito', 'Bebidas', net: 1000, cost: 200),
      _product('Agua', 'Bebidas', net: 100, cost: 90),
      _product('Pizza', 'Comida', net: 500, cost: 400, discounts: 50),
    ].map(ReportCatalog.productRecord).toList();

    test('margen total ponderado, no promedio de promedios', () {
      final table = _build(definition, records, definition.defaultConfig);
      final margin = table.totals[_col(table, ReportColumnIds.marginPct)];
      // Σ ganancia (800 + 10 + 100) ÷ Σ netas (1600) = 56.875 %.
      expect(margin.raw, closeTo(56.875, 1e-9));
      // El promedio simple de márgenes (80 + 10 + 20) / 3 = 36.7 % sería falso.
      expect(margin.text, '56.9 %');
    });

    test('agrupar por categoría: subtotales, no sumables en blanco', () {
      final config = definition.defaultConfig.copyWith(
        columns: [
          ReportColumnIds.position,
          ReportColumnIds.label,
          ReportColumnIds.category,
          ReportColumnIds.amount,
          ReportColumnIds.share,
          ReportColumnIds.amountPerCount,
          ReportColumnIds.marginPct,
        ],
        groupBy: ReportColumnIds.category,
      );
      final table = _build(definition, records, config);
      final subtotals = table.rows
          .where((r) => r.type == ReportTableRowType.subtotal)
          .toList();
      expect(subtotals.map((r) => r.groupLabel), ['Bebidas', 'Comida']);
      final bebidas = subtotals.first.cells;
      expect(bebidas[_col(table, ReportColumnIds.amount)].raw, 1100);
      expect(bebidas[_col(table, ReportColumnIds.amountPerCount)].text, '');
      expect(bebidas[_col(table, ReportColumnIds.position)].text, '');
      // Participación del bloque = Σ de sus filas.
      expect(bebidas[_col(table, ReportColumnIds.share)].raw,
          closeTo(1100 / 1600 * 100, 1e-9));
      // Margen del bloque, ponderado: 810 ÷ 1100.
      expect(bebidas[_col(table, ReportColumnIds.marginPct)].raw,
          closeTo(810 / 1100 * 100, 1e-9));
      expect(table.rows.first.type, ReportTableRowType.groupHeader);
    });

    test('descuentos llevan tono ámbar; ganancia y margen, signo', () {
      expect(definition.column(ReportColumnIds.discounts)!.tone,
          ReportCellTone.cautionWhenPositive);
      expect(definition.column(ReportColumnIds.grossProfit)!.tone,
          ReportCellTone.signed);
      expect(definition.column(ReportColumnIds.marginPct)!.tone,
          ReportCellTone.signed);
    });
  });

  group('detalle por comprobante', () {
    const fee = 'Propina legal';
    final docs = <Map<String, dynamic>>[
      {
        'ncf_number': 'B0100000001',
        'ncf_type': 'B01',
        'customer_name': 'ACME SRL',
        'customer_rnc': '101000001',
        'subtotal': 1000,
        'tax_breakdown': [
          {'label': 'ITBIS', 'rate': 18, 'tax_amount': 180},
        ],
        'service_fee': 100,
        'total': 1280,
        'status': 'active',
        'issued_at': '2026-09-10T15:00:00Z',
      },
      {
        'ncf_number': 'B0200000002',
        'ncf_type': 'B02',
        'customer_name': null,
        'customer_rnc': '',
        'subtotal': 500,
        'tax_breakdown': [
          {'label': 'ITBIS', 'rate': 18, 'tax_amount': 90},
        ],
        'service_fee': 0,
        'total': 590,
        'status': 'void',
        'issued_at': '2026-09-11T15:00:00Z',
      },
    ];

    late ReportDefinition definition;
    late List<ReportRecord> records;

    setUp(() {
      final taxes = ReportCatalog.documentTaxLabels(docs, fee);
      definition = ReportCatalog.fiscalDocuments(
        taxLabels: taxes,
        serviceFeeLabel: fee,
        hasServiceFee: ReportCatalog.documentsHaveServiceFee(docs),
      );
      records = [
        for (final doc in docs)
          ReportCatalog.documentRecord(doc,
              taxLabels: taxes, serviceFeeLabel: fee),
      ];
    });

    test('el anulado se lista pero no entra en subtotal, ITBIS ni total', () {
      final table = _build(
        definition,
        records,
        definition.preset('full')!.config,
      );
      expect(table.dataRowCount, 2);
      expect(table.validRowCount, 1);
      expect(table.excludedRowCount, 1);
      expect(table.excludedAmount, 590);
      expect(table.totals[_col(table, ReportColumnIds.subtotal)].raw, 1000);
      expect(
          table.totals[_col(table, '${ReportColumnIds.taxPrefix}ITBIS (18%)')]
              .raw,
          180);
      expect(table.totals[_col(table, ReportColumnIds.total)].raw, 1280);
      expect(table.totalLabel, 'Total de 1 documento válido');
      final voided = table.dataRows.firstWhere((r) => r.excluded);
      expect(voided.cells[_col(table, ReportColumnIds.share)].text,
          ReportFormats.missing);
    });

    test('el cargo de servicio va en su propia columna, no como impuesto', () {
      expect(definition.column('${ReportColumnIds.taxPrefix}$fee'), isNull);
      expect(definition.column(ReportColumnIds.serviceFee)!.label, fee);
      expect(definition.defaultConfig.columns,
          contains(ReportColumnIds.serviceFee));
    });

    test('vista para el contador empieza por RNC, ordenada por fecha', () {
      final config = definition.preset('accountant')!.config;
      expect(config.columns.first, ReportColumnIds.customerRnc);
      expect(config.sortColumn, ReportColumnIds.issuedAt);
      expect(config.sortAscending, isTrue);
    });
  });

  group('ReportViewConfig', () {
    final definition = _breakdown(_categoryLabels);

    test('normaliza: descarta ids viejos y garantiza el eje bloqueado', () {
      const config = ReportViewConfig(
        columns: [ReportColumnIds.amount, 'tax:ya_no_existe'],
        sortColumn: ReportColumnIds.count,
        groupBy: ReportColumnIds.amount,
      );
      final normalized = config.normalizedFor(definition);
      expect(normalized.columns,
          [ReportColumnIds.label, ReportColumnIds.amount]);
      // Ordenar por una columna no visible no aplica; tampoco agrupar por una
      // que no es agrupable.
      expect(normalized.sortColumn, isNull);
      expect(normalized.groupBy, isNull);
    });

    test('no se ordena por columnas que dependen del orden', () {
      const config = ReportViewConfig(
        columns: [ReportColumnIds.label, ReportColumnIds.cumulative],
        sortColumn: ReportColumnIds.cumulative,
      );
      expect(config.normalizedFor(definition).sortColumn, isNull);
    });

    test('ida y vuelta por JSON (sin rango de fechas)', () {
      const config = ReportViewConfig(
        columns: [ReportColumnIds.label, ReportColumnIds.amount],
        sortColumn: ReportColumnIds.amount,
        sortAscending: true,
        density: ReportDensity.compact,
      );
      final json = config.toJson();
      expect(json.keys, isNot(contains('from')));
      final back = ReportViewConfig.fromJson(json)!;
      expect(back.columns, config.columns);
      expect(back.sortColumn, ReportColumnIds.amount);
      expect(back.sortAscending, isTrue);
      expect(back.density, ReportDensity.compact);
    });

    test('"Guardar vista" aparece al modificar columnas, no por densidad', () {
      var state = const ReportViewPreferencesState();
      expect(state.isModified(definition), isFalse);
      state = state.copyWith(active: {
        definition.key: definition.defaultConfig
            .copyWith(density: ReportDensity.compact),
      });
      expect(state.isModified(definition), isFalse);
      state = state.copyWith(active: {
        definition.key: definition.defaultConfig.copyWith(
          columns: [ReportColumnIds.label, ReportColumnIds.amount],
        ),
      });
      expect(state.isModified(definition), isTrue);
    });
  });
}
