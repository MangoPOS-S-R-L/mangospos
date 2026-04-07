import 'dart:convert';

import 'package:file_picker/file_picker.dart';

import '../viewmodel/reports_viewmodel.dart';

class ReportsCsvExportService {
  static Future<void> exportCurrentReport({
    required ReportCategory category,
    required ReportsState state,
    required ReportsViewModel viewModel,
  }) async {
    final csv = _buildCsv(category, state, viewModel);
    final filename =
        'reporte_${category.name}_${DateTime.now().millisecondsSinceEpoch}.csv';

    await FilePicker.platform.saveFile(
      dialogTitle: 'Guardar reporte CSV',
      fileName: filename,
      bytes: utf8.encode(csv),
    );
  }

  static String _buildCsv(
    ReportCategory category,
    ReportsState state,
    ReportsViewModel viewModel,
  ) {
    final rows = <List<String>>[];
    rows.add([viewModel.getCategoryTitle(category)]);
    rows.add([
      'Desde',
      state.salesFrom.toIso8601String(),
      'Hasta',
      state.salesTo.subtract(const Duration(days: 1)).toIso8601String(),
    ]);
    rows.add([]);

    void addMetricSection(List<SalesMetricCardData> metrics) {
      rows.add(['Métrica', 'Valor', 'Detalle']);
      for (final metric in metrics) {
        rows.add([metric.title, metric.value, metric.subtitle]);
      }
      rows.add([]);
    }

    void addBreakdownSection(String title, List<SalesBreakdownRow> breakdown) {
      rows.add([title]);
      rows.add(['Concepto', 'Monto', 'Cantidad', 'Conteo']);
      for (final row in breakdown) {
        rows.add([
          row.label,
          row.amount.toStringAsFixed(2),
          row.quantity.toStringAsFixed(2),
          row.count.toString(),
        ]);
      }
      rows.add([]);
    }

    switch (category) {
      case ReportCategory.sales:
        addMetricSection(viewModel.getSalesMetricCards());
        addBreakdownSection(
          'Métodos de pago',
          viewModel.getPaymentMethodRows(),
        );
        addBreakdownSection('Top productos', viewModel.getTopProductRows());
        addBreakdownSection(
          'Ventas por categoría',
          viewModel.getCategoryRows(),
        );
        addBreakdownSection(
          'Ventas por empleado',
          viewModel.getEmployeeRows(),
        );
        addBreakdownSection('Ventas por zona', viewModel.getZoneRows());
        addBreakdownSection('Ventas por hora', viewModel.getHourlyRows());
        break;
      case ReportCategory.finances:
        addMetricSection(viewModel.getFinanceMetricCards());
        addBreakdownSection(
          'Movimientos por tipo',
          viewModel.getFinanceTypeRows(),
        );
        addBreakdownSection('Sesiones', viewModel.getFinanceSessionRows());
        break;
      case ReportCategory.inventory:
        addMetricSection(viewModel.getInventoryMetricCards());
        addBreakdownSection('Top stock', viewModel.getInventoryTopStockRows());
        addBreakdownSection('Alertas', viewModel.getInventoryAlertRows());
        addBreakdownSection(
          'Movimientos',
          viewModel.getInventoryMovementRows(),
        );
        break;
      case ReportCategory.purchases:
        addMetricSection(viewModel.getPurchaseMetricCards());
        addBreakdownSection('Estados', viewModel.getPurchaseStatusRows());
        addBreakdownSection(
          'Top proveedores',
          viewModel.getPurchaseSupplierRows(),
        );
        break;
      case ReportCategory.taxes:
        addMetricSection(viewModel.getTaxMetricCards());
        addBreakdownSection('Impuestos por tipo', viewModel.getTaxTypeRows());
        break;
    }

    return rows.map(_toCsvLine).join('\n');
  }

  static String _toCsvLine(List<String> cells) {
    return cells.map((cell) => '"${cell.replaceAll('"', '""')}"').join(',');
  }
}
