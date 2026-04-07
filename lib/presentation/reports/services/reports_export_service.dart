import 'package:intl/intl.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../viewmodel/reports_viewmodel.dart';

class ReportsExportService {
  static Future<void> exportCurrentReport({
    required ReportCategory category,
    required ReportsState state,
    required ReportsViewModel viewModel,
  }) async {
    final pdf = pw.Document();
    final dateFormat = DateFormat('dd/MM/yyyy');
    final from = dateFormat.format(state.salesFrom);
    final to = dateFormat.format(
      state.salesTo.subtract(const Duration(days: 1)),
    );

    pdf.addPage(
      pw.MultiPage(
        build: (context) => [
          pw.Text(
            viewModel.getCategoryTitle(category),
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Text('Rango: $from - $to'),
          pw.SizedBox(height: 16),
          ..._buildCategoryContent(category, state, viewModel),
        ],
      ),
    );

    final filename =
        'reporte_${category.name}_${DateTime.now().millisecondsSinceEpoch}.pdf';
    await Printing.sharePdf(bytes: await pdf.save(), filename: filename);
  }

  static List<pw.Widget> _buildCategoryContent(
    ReportCategory category,
    ReportsState state,
    ReportsViewModel viewModel,
  ) {
    switch (category) {
      case ReportCategory.sales:
        return [
          _metricsTable(viewModel.getSalesMetricCards()),
          pw.SizedBox(height: 16),
          _breakdownTable('Métodos de pago', viewModel.getPaymentMethodRows()),
          pw.SizedBox(height: 12),
          _breakdownTable(
            'Top productos',
            viewModel.getTopProductRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          _breakdownTable(
            'Ventas por categoría',
            viewModel.getCategoryRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          _breakdownTable(
              'Ventas por empleado', viewModel.getEmployeeRows()),
          pw.SizedBox(height: 12),
          _breakdownTable('Ventas por zona', viewModel.getZoneRows()),
          pw.SizedBox(height: 12),
          _breakdownTable('Ventas por hora', viewModel.getHourlyRows()),
        ];
      case ReportCategory.finances:
        return [
          _metricsTable(viewModel.getFinanceMetricCards()),
          pw.SizedBox(height: 16),
          _breakdownTable(
            'Movimientos por tipo',
            viewModel.getFinanceTypeRows(),
          ),
          pw.SizedBox(height: 12),
          _breakdownTable('Sesiones', viewModel.getFinanceSessionRows()),
        ];
      case ReportCategory.inventory:
        return [
          _metricsTable(viewModel.getInventoryMetricCards()),
          pw.SizedBox(height: 16),
          _breakdownTable(
            'Top stock',
            viewModel.getInventoryTopStockRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          _breakdownTable(
            'Alertas',
            viewModel.getInventoryAlertRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          _breakdownTable('Movimientos', viewModel.getInventoryMovementRows()),
        ];
      case ReportCategory.purchases:
        return [
          _metricsTable(viewModel.getPurchaseMetricCards()),
          pw.SizedBox(height: 16),
          _breakdownTable('Estados', viewModel.getPurchaseStatusRows()),
          pw.SizedBox(height: 12),
          _breakdownTable(
            'Top proveedores',
            viewModel.getPurchaseSupplierRows(),
          ),
        ];
      case ReportCategory.taxes:
        return [
          _metricsTable(viewModel.getTaxMetricCards()),
          pw.SizedBox(height: 16),
          _breakdownTable(
            'Impuestos por tipo',
            viewModel.getTaxTypeRows(),
            showQuantity: true,
          ),
        ];
    }
  }

  static pw.Widget _metricsTable(List<SalesMetricCardData> metrics) {
    return pw.TableHelper.fromTextArray(
      headers: const ['Métrica', 'Valor', 'Detalle'],
      data: metrics
          .map((m) => [m.title, m.value, m.subtitle])
          .toList(growable: false),
    );
  }

  static pw.Widget _breakdownTable(
    String title,
    List<SalesBreakdownRow> rows, {
    bool showQuantity = false,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(title, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        pw.TableHelper.fromTextArray(
          headers: showQuantity
              ? const ['Concepto', 'Monto', 'Cantidad', 'Conteo']
              : const ['Concepto', 'Monto', 'Conteo'],
          data: rows
              .map(
                (r) => showQuantity
                    ? [
                        r.label,
                        r.amount.toStringAsFixed(2),
                        r.quantity.toStringAsFixed(2),
                        r.count.toString(),
                      ]
                    : [
                        r.label,
                        r.amount.toStringAsFixed(2),
                        r.count.toString(),
                      ],
              )
              .toList(growable: false),
        ),
      ],
    );
  }
}
