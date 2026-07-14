import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';

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

    await FilePicker.saveFile(
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

    // Label del service fee derivado de la configuración del comercio
    // (`service_fee_label`). Antes era "Propina de ley" hardcoded — rompía
    // multi-país y multi-configuración.
    final serviceFeeLabel =
        (state.fiscalSummary?['service_fee_label'] as String?)?.trim();
    final effectiveServiceFeeLabel =
        (serviceFeeLabel?.isNotEmpty ?? false)
            ? serviceFeeLabel!
            : 'Cargo de servicio';

    void addFiscalDocumentsDetail(List<Map<String, dynamic>> fiscalDocs) {
      if (fiscalDocs.isEmpty) return;
      final taxLabels =
          _collectTaxLabels(fiscalDocs, effectiveServiceFeeLabel);
      rows.add(['Detalle de comprobantes']);
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
            final amount = _taxAmountForLabel(
              doc,
              label,
              effectiveServiceFeeLabel,
            );
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
    }

    void addProductSalesSection(List<ProductSalesReportRow> productRows) {
      rows.add(['Ventas por producto']);
      rows.add([
        'Producto',
        'Categoría',
        'Cantidad vendida',
        'Ventas brutas',
        'Descuentos',
        'Cortesías',
        'Ventas netas',
        'Costo',
        'Ganancia bruta',
        'Margen %',
        'Tickets',
      ]);
      for (final row in productRows) {
        rows.add([
          row.product,
          row.category,
          row.quantitySold.toStringAsFixed(2),
          row.grossSales.toStringAsFixed(2),
          row.discounts.toStringAsFixed(2),
          row.courtesies.toStringAsFixed(2),
          row.netSales.toStringAsFixed(2),
          row.cost.toStringAsFixed(2),
          row.grossProfit.toStringAsFixed(2),
          row.marginPct == null ? '' : row.marginPct!.toStringAsFixed(1),
          row.tickets.toString(),
        ]);
      }
      rows.add([]);
    }

    switch (category) {
      case ReportCategory.sales:
        addMetricSection(viewModel.getSalesMetricCards());
        // Sub-reporte "Por comprobante" sale enfocado: solo métricas
        // + tabla de comprobantes. Mismo formato limpio que el reporte
        // de impuestos.
        if (state.salesSubReport == SalesSubReport.byReceipt) {
          addBreakdownSection(
            'Ventas por recibo / comprobante',
            viewModel.getReceiptRows(),
          );
          addFiscalDocumentsDetail(viewModel.getFiscalDocuments());
          break;
        }
        addBreakdownSection(
          'Ventas por tipo de pago',
          viewModel.getPaymentMethodRows(),
        );
        addBreakdownSection(
          'Ventas por categoría',
          viewModel.getCategoryRows(),
        );
        addBreakdownSection('Ventas por empleado', viewModel.getEmployeeRows());
        addBreakdownSection(
          'Ventas por recibo / comprobante',
          viewModel.getReceiptRows(),
        );
        addBreakdownSection(
          'Ventas por modificadores',
          viewModel.getModifierRows(),
        );
        addBreakdownSection(
          'Descuentos y cortesías',
          viewModel.getDiscountRows(),
        );
        addProductSalesSection(viewModel.getFilteredProductSalesRows());
        addBreakdownSection('Top productos', viewModel.getTopProductRows());
        addBreakdownSection('Ventas por zona', viewModel.getZoneRows());
        addBreakdownSection('Ventas por hora', viewModel.getHourlyRows());
        break;
      case ReportCategory.offers:
        final offerDate = DateFormat('dd/MM/yyyy HH:mm:ss');
        // Pivote: cantidad por producto.
        rows.add(['Productos en oferta']);
        rows.add(['Producto', 'Cantidad']);
        for (final row in viewModel.getOfferProductTotals()) {
          rows.add([row.productName, row.quantity.toStringAsFixed(2)]);
        }
        rows.add([
          'Suma total',
          viewModel.offersTotalQuantity.toStringAsFixed(2),
        ]);
        rows.add([]);
        // Detalle: una fila por cada vez que se aplicó una oferta.
        rows.add(['Detalle de ofertas']);
        rows.add([
          'Fecha',
          'Oferta',
          'Producto',
          'Cantidad',
          'Valor a precio de menú',
          'Descuento otorgado',
        ]);
        for (final row in viewModel.getOfferDetailRows()) {
          rows.add([
            row.dateTime != null ? offerDate.format(row.dateTime!) : '',
            row.offerName,
            row.productName,
            row.quantity.toStringAsFixed(2),
            row.valorMenu.toStringAsFixed(2),
            row.descuento.toStringAsFixed(2),
          ]);
        }
        rows.add([
          'Total',
          '',
          '',
          viewModel.offersTotalQuantity.toStringAsFixed(2),
          viewModel.offersTotalValorMenu.toStringAsFixed(2),
          viewModel.offersTotalDescuento.toStringAsFixed(2),
        ]);
        rows.add([]);
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
        // Misma fuente que el view (fiscalSummary). Ver comentario en
        // reports_export_service.dart sobre por qué cambiamos de
        // getTaxMetricCards a getTaxReportMetricCards.
        addMetricSection(viewModel.getTaxReportMetricCards());
        addBreakdownSection(
          'Total facturado por tipo de comprobante',
          viewModel.getTaxReportTypeRows(),
        );
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
        addFiscalDocumentsDetail(viewModel.getFiscalDocuments());
        break;
    }

    return rows.map(_toCsvLine).join('\n');
  }

  static String _toCsvLine(List<String> cells) {
    return cells.map((cell) => '"${cell.replaceAll('"', '""')}"').join(',');
  }

  // Skip "Impuesto X%" entries — fallback de tax_rate combinado que no
  // pudo desdoblarse contra impuestos configurados (ej. 28% = ITBIS+Ley).
  static final RegExp _kUnmappedTaxLabelRe = RegExp(r'^Impuesto\s');

  static List<String> _collectTaxLabels(
    List<Map<String, dynamic>> documents,
    String serviceFeeLabel,
  ) {
    final labels = <String>{};
    for (final doc in documents) {
      final breakdown = doc['tax_breakdown'];
      if (breakdown is List) {
        for (final item in breakdown) {
          final m = item is Map<String, dynamic>
              ? item
              : Map<String, dynamic>.from(item as Map);
          final label = m['label']?.toString() ?? '';
          if (_kUnmappedTaxLabelRe.hasMatch(label)) continue;
          final rate = (m['rate'] as num?)?.toDouble() ?? 0;
          final display = rate > 0
              ? '$label (${rate.toStringAsFixed(rate.truncateToDouble() == rate ? 0 : 2)}%)'
              : label;
          if (display.isNotEmpty) labels.add(display);
        }
      }
      final sf = (doc['service_fee'] as num?)?.toDouble() ?? 0;
      if (sf > 0) labels.add(serviceFeeLabel);
    }
    return labels.toList(growable: false);
  }

  static double _taxAmountForLabel(
    Map<String, dynamic> doc,
    String label,
    String serviceFeeLabel,
  ) {
    if (label == serviceFeeLabel) {
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
