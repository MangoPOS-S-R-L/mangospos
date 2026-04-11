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
      case ReportCategory.fiscal:
        addMetricSection(viewModel.getFiscalMetricCards());
        addBreakdownSection(
          'Comprobantes por tipo de NCF',
          viewModel.getFiscalTypeRows(),
        );
        addBreakdownSection(
          'Desglose por tipo de impuesto',
          viewModel.getFiscalTaxBreakdownRows(),
        );
        final fiscalDocs = viewModel.getFiscalDocuments();
        final taxLabels = _collectTaxLabels(fiscalDocs);
        rows.add(['Detalle de comprobantes fiscales (DGII)']);
        rows.add([
          'NCF',
          'Tipo',
          'Cliente',
          'RNC/Cédula',
          'Subtotal',
          ...taxLabels,
          'Total',
          'Estado',
          'Fecha',
        ]);
        for (final doc in fiscalDocs) {
          final issuedAt =
              DateTime.tryParse(doc['issued_at']?.toString() ?? '') ??
                  DateTime.now();
          rows.add([
            doc['ncf_number']?.toString() ?? '',
            doc['ncf_type']?.toString() ?? '',
            doc['customer_name']?.toString() ?? 'CONSUMIDOR FINAL',
            doc['customer_rnc']?.toString() ?? '-',
            ((doc['subtotal'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
            ...taxLabels.map((label) {
              final amount = _taxAmountForLabel(doc, label);
              return amount > 0 ? amount.toStringAsFixed(2) : '0.00';
            }),
            ((doc['total'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
            (doc['status']?.toString() ?? 'active') == 'active'
                ? 'Activo'
                : 'Anulado',
            issuedAt.toLocal().toIso8601String(),
          ]);
        }
        rows.add([]);
        break;
    }

    return rows.map(_toCsvLine).join('\n');
  }

  static String _toCsvLine(List<String> cells) {
    return cells.map((cell) => '"${cell.replaceAll('"', '""')}"').join(',');
  }

  static List<String> _collectTaxLabels(
      List<Map<String, dynamic>> documents) {
    final labels = <String>{};
    for (final doc in documents) {
      final breakdown = doc['tax_breakdown'];
      if (breakdown is List) {
        for (final item in breakdown) {
          final m = item is Map<String, dynamic>
              ? item
              : Map<String, dynamic>.from(item as Map);
          final label = m['label']?.toString() ?? '';
          final rate = (m['rate'] as num?)?.toDouble() ?? 0;
          final display = rate > 0
              ? '$label (${rate.toStringAsFixed(rate.truncateToDouble() == rate ? 0 : 2)}%)'
              : label;
          if (display.isNotEmpty) labels.add(display);
        }
      }
      final sf = (doc['service_fee'] as num?)?.toDouble() ?? 0;
      if (sf > 0) labels.add('Propina de ley');
    }
    return labels.toList(growable: false);
  }

  static double _taxAmountForLabel(
      Map<String, dynamic> doc, String label) {
    if (label == 'Propina de ley') {
      return (doc['service_fee'] as num?)?.toDouble() ?? 0;
    }
    final breakdown = doc['tax_breakdown'];
    if (breakdown is! List) return 0;
    for (final item in breakdown) {
      final m = item is Map<String, dynamic>
          ? item
          : Map<String, dynamic>.from(item as Map);
      final itemLabel = m['label']?.toString() ?? '';
      final rate = (m['rate'] as num?)?.toDouble() ?? 0;
      final display = rate > 0
          ? '$itemLabel (${rate.toStringAsFixed(rate.truncateToDouble() == rate ? 0 : 2)}%)'
          : itemLabel;
      if (display == label) {
        return (m['tax_amount'] as num?)?.toDouble() ?? 0;
      }
    }
    return 0;
  }
}
