import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/fiscal/ncf_types.dart';
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

    final title =
        category == ReportCategory.sales &&
            state.salesSubReport == SalesSubReport.byReceipt
        ? 'Reporte de comprobantes'
        : viewModel.getCategoryTitle(category);

    // Reportes con detalle de comprobantes (fiscal, byReceipt) suelen
    // tener tablas anchas (NCF + cliente + RNC + N columnas de impuestos
    // + total + estado + fecha) y muchas filas. Landscape + maxPages
    // alto evita TooManyPagesException cuando el rango cubre semanas
    // de operación. Las otras categorías mantienen retrato y márgenes
    // estándar.
    final useLandscape =
        category == ReportCategory.fiscal ||
        (category == ReportCategory.sales &&
            state.salesSubReport == SalesSubReport.byReceipt);
    final pageFormat = useLandscape
        ? PdfPageFormat.a4.landscape
        : PdfPageFormat.a4;

    pdf.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        maxPages: 500,
        margin: const pw.EdgeInsets.all(24),
        build: (context) => [
          pw.Text(
            title,
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
        // Sub-reporte "Por comprobante" sale enfocado al estilo del
        // PDF de impuestos: solo métricas + tabla de comprobantes.
        // El dump completo de ventas (categorías, empleados, productos,
        // etc.) solo se exporta en "Vista general".
        if (state.salesSubReport == SalesSubReport.byReceipt) {
          return [
            _metricsTable(viewModel.getSalesMetricCards()),
            pw.SizedBox(height: 16),
            ..._breakdownTable(
              'Ventas por recibo / comprobante',
              viewModel.getReceiptRows(),
            ),
            pw.SizedBox(height: 16),
            // Cada comprobante listado individualmente con su estado
            // (Activo/Anulado), igual que el reporte fiscal. Respeta el
            // toggle "Ver anulados": por defecto el PDF sale solo con los
            // válidos, que son los que suman a los totales de arriba.
            ..._fiscalDocumentsTable(
              viewModel.getVisibleFiscalDocuments(),
              _serviceFeeLabelOf(state),
            ),
          ];
        }
        return [
          _metricsTable(viewModel.getSalesMetricCards()),
          pw.SizedBox(height: 16),
          ..._breakdownTable(
            'Ventas por tipo de pago',
            viewModel.getPaymentMethodRows(),
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Ventas por categoría',
            viewModel.getCategoryRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable('Ventas por empleado', viewModel.getEmployeeRows()),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Ventas por recibo / comprobante',
            viewModel.getReceiptRows(),
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Ventas por modificadores',
            viewModel.getModifierRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Descuentos y cortesías',
            viewModel.getDiscountRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          ..._productSalesTable(viewModel.getFilteredProductSalesRows()),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Top productos',
            viewModel.getTopProductRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable('Ventas por zona', viewModel.getZoneRows()),
          pw.SizedBox(height: 12),
          ..._breakdownTable('Ventas por hora', viewModel.getHourlyRows()),
        ];
      case ReportCategory.offers:
        return [
          ..._offerProductTotalsTable(viewModel),
          pw.SizedBox(height: 16),
          ..._offersDetailTable(viewModel),
        ];
      case ReportCategory.delivery:
        return _deliveryDetailTable(viewModel);
      case ReportCategory.finances:
        return [
          _metricsTable(viewModel.getFinanceMetricCards()),
          pw.SizedBox(height: 16),
          ..._breakdownTable(
            'Movimientos por tipo',
            viewModel.getFinanceTypeRows(),
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable('Sesiones', viewModel.getFinanceSessionRows()),
        ];
      case ReportCategory.inventory:
        return [
          _metricsTable(viewModel.getInventoryMetricCards()),
          pw.SizedBox(height: 16),
          ..._breakdownTable(
            'Top stock',
            viewModel.getInventoryTopStockRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Alertas',
            viewModel.getInventoryAlertRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable('Movimientos', viewModel.getInventoryMovementRows()),
        ];
      case ReportCategory.purchases:
        return [
          _metricsTable(viewModel.getPurchaseMetricCards()),
          pw.SizedBox(height: 16),
          ..._breakdownTable('Estados', viewModel.getPurchaseStatusRows()),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Top proveedores',
            viewModel.getPurchaseSupplierRows(),
          ),
        ];
      case ReportCategory.taxes:
        // FUENTE: fiscalSummary (tabla fiscal_documents = NCFs emitidos).
        // ANTES usaba getTaxMetricCards/getTaxTypeRows (reconstrucción Dart
        // desde payments+items) y daba números distintos a los del view
        // (delta 30%+). Ahora ambos toman de la misma fuente.
        return [
          _metricsTable(viewModel.getTaxReportMetricCards()),
          pw.SizedBox(height: 16),
          ..._breakdownTable(
            'Total facturado por tipo de comprobante',
            viewModel.getTaxReportTypeRows(),
            showQuantity: true,
          ),
        ];
      case ReportCategory.fiscal:
        return [
          _metricsTable(viewModel.getFiscalMetricCards()),
          pw.SizedBox(height: 16),
          ..._breakdownTable(
            'Comprobantes por tipo de NCF',
            viewModel.getFiscalTypeRows(),
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Desglose por tipo de impuesto',
            viewModel.getFiscalTaxBreakdownRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 16),
          // Respeta el toggle "Ver anulados" (el filtro de tipo se deja fuera
          // a propósito: el PDF fiscal siempre exportó el rango completo).
          ..._fiscalDocumentsTable(
              viewModel.getVisibleFiscalDocuments(),
              _serviceFeeLabelOf(state),
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

  /// Pivote: cantidad despachada por producto, con la suma total al final.
  static List<pw.Widget> _offerProductTotalsTable(ReportsViewModel viewModel) {
    final rows = viewModel.getOfferProductTotals();
    if (rows.isEmpty) return [];
    final qtyFormat = NumberFormat('#,##0.##', 'en_US');
    final data = rows
        .map((row) => [row.productName, qtyFormat.format(row.quantity)])
        .toList();
    data.add(['Suma total', qtyFormat.format(viewModel.offersTotalQuantity)]);
    return [
      pw.Text(
        'Productos en oferta',
        style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headers: const ['Producto', 'Cantidad'],
        data: data,
      ),
    ];
  }

  /// Listado detallado: una fila por cada vez que se aplicó una oferta.
  static List<pw.Widget> _deliveryDetailTable(ReportsViewModel viewModel) {
    final rows = viewModel.getDeliveryFeeRows();
    if (rows.isEmpty) return [];
    final moneyFormat = NumberFormat('#,##0.00', 'en_US');
    final dateFormat = DateFormat('dd/MM/yyyy HH:mm:ss');
    return [
      pw.Text(
        'Fees de delivery cobrados',
        style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headers: const [
          'Fecha de cobro',
          'Cliente',
          'Total de la orden',
          'Fee de delivery',
        ],
        data: [
          ...rows.map(
            (row) => [
              row.paidAt != null ? dateFormat.format(row.paidAt!) : '',
              row.customerName,
              moneyFormat.format(row.orderTotal),
              moneyFormat.format(row.deliveryFee),
            ],
          ),
          [
            'Total',
            '${viewModel.deliveryOrdersCount} órdenes',
            moneyFormat.format(viewModel.deliveryTotalOrdersAmount),
            moneyFormat.format(viewModel.deliveryTotalFees),
          ],
        ],
      ),
    ];
  }

  static List<pw.Widget> _offersDetailTable(ReportsViewModel viewModel) {
    final rows = viewModel.getOfferDetailRows();
    if (rows.isEmpty) return [];
    final qtyFormat = NumberFormat('#,##0.##', 'en_US');
    final moneyFormat = NumberFormat('#,##0.00', 'en_US');
    final dateFormat = DateFormat('dd/MM/yyyy HH:mm:ss');
    return [
      pw.Text(
        'Detalle de ofertas',
        style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headers: const [
          'Fecha',
          'Oferta',
          'Producto',
          'Cantidad',
          'Valor a precio de menú',
          'Descuento otorgado',
        ],
        data: [
          ...rows.map(
            (row) => [
              row.dateTime != null ? dateFormat.format(row.dateTime!) : '',
              row.offerName,
              row.productName,
              qtyFormat.format(row.quantity),
              moneyFormat.format(row.valorMenu),
              moneyFormat.format(row.descuento),
            ],
          ),
          [
            'Total',
            '',
            '',
            qtyFormat.format(viewModel.offersTotalQuantity),
            moneyFormat.format(viewModel.offersTotalValorMenu),
            moneyFormat.format(viewModel.offersTotalDescuento),
          ],
        ],
      ),
    ];
  }

  static List<pw.Widget> _productSalesTable(List<ProductSalesReportRow> rows) {
    if (rows.isEmpty) return [];
    final numberFormat = NumberFormat('#,##0.00', 'en_US');
    return [
      pw.Text(
        'Ventas por producto',
        style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        cellStyle: const pw.TextStyle(fontSize: 8),
        headers: const [
          'Producto',
          'Categoría',
          'Cant.',
          'Brutas',
          'Desc.',
          'Cortesías',
          'Netas',
          'Costo',
          'Gan. bruta',
          'Margen %',
        ],
        data: rows
            .map(
              (row) => [
                row.product,
                row.category,
                numberFormat.format(row.quantitySold),
                numberFormat.format(row.grossSales),
                numberFormat.format(row.discounts),
                numberFormat.format(row.courtesies),
                numberFormat.format(row.netSales),
                numberFormat.format(row.cost),
                numberFormat.format(row.grossProfit),
                row.marginPct == null
                    ? '--'
                    : '${row.marginPct!.toStringAsFixed(1)}%',
              ],
            )
            .toList(growable: false),
      ),
    ];
  }

  // _ncfTypeName eliminado: ahora se usa `ncfTypeName(code)` de
  // core/fiscal/ncf_types.dart (catálogo único para toda la app).

  // Skip "Impuesto X%" entries — fallback que produce el repositorio
  // cuando el tax_rate combinado (ej. 28% = ITBIS+Propina) no pudo
  // desdoblarse, y crea una columna extra que rompe el layout.
  static final RegExp _kUnmappedTaxLabelRe = RegExp(r'^Impuesto\s');

  /// Label del service fee derivado de la config del comercio
  /// (`fiscalSummary.service_fee_label`). Fallback genérico — antes era
  /// "Propina de ley" hardcoded en varios lugares.
  static String _serviceFeeLabelOf(ReportsState state) {
    final raw =
        (state.fiscalSummary?['service_fee_label'] as String?)?.trim();
    return (raw?.isNotEmpty ?? false) ? raw! : 'Cargo de servicio';
  }

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

  static List<pw.Widget> _fiscalDocumentsTable(
    List<Map<String, dynamic>> documents,
    String serviceFeeLabel,
  ) {
    if (documents.isEmpty) {
      return [
        pw.Text('No hay comprobantes fiscales en el rango seleccionado.'),
      ];
    }

    final dateFormat = DateFormat('dd/MM/yyyy');
    final numberFormat = NumberFormat('#,##0.00', 'en_US');
    final taxLabels = _collectTaxLabels(documents, serviceFeeLabel);

    return [
      pw.Text(
        'Detalle de comprobantes fiscales (DGII)',
        style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 14),
      ),
      pw.SizedBox(height: 8),
      pw.Text(
        'Total: ${documents.length} comprobantes',
        style: const pw.TextStyle(fontSize: 10),
      ),
      pw.SizedBox(height: 8),
      pw.TableHelper.fromTextArray(
        cellAlignment: pw.Alignment.centerLeft,
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8),
        cellStyle: const pw.TextStyle(fontSize: 7),
        headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#E5E7EB')),
        headers: [
          'NCF',
          'Tipo',
          'Cliente',
          'RNC/Cédula',
          'Subtotal',
          ...taxLabels,
          'Total',
          'Estado',
          'Fecha',
        ],
        data: documents
            .map((doc) {
              final ncfNumber = doc['ncf_number']?.toString() ?? '';
              final ncfType = doc['ncf_type']?.toString() ?? '';
              final customerName =
                  doc['customer_name']?.toString() ?? 'CONSUMIDOR FINAL';
              final customerRnc = doc['customer_rnc']?.toString() ?? '-';
              final subtotal = (doc['subtotal'] as num?)?.toDouble() ?? 0;
              final total = (doc['total'] as num?)?.toDouble() ?? 0;
              final status = doc['status']?.toString() ?? 'active';
              final issuedAt =
                  DateTime.tryParse(doc['issued_at']?.toString() ?? '') ??
                  DateTime.now();

              return [
                ncfNumber,
                ncfTypeName(ncfType),
                customerName.length > 25
                    ? '${customerName.substring(0, 25)}...'
                    : customerName,
                customerRnc.isEmpty ? '-' : customerRnc,
                numberFormat.format(subtotal),
                ...taxLabels.map((label) {
                  final amount =
                      _taxAmountForLabel(doc, label, serviceFeeLabel);
                  return amount > 0 ? numberFormat.format(amount) : '-';
                }),
                numberFormat.format(total),
                status == 'active' ? 'Activo' : 'Anulado',
                dateFormat.format(issuedAt.toLocal()),
              ];
            })
            .toList(growable: false),
      ),
    ];
  }

  static List<pw.Widget> _breakdownTable(
    String title,
    List<SalesBreakdownRow> rows, {
    bool showQuantity = false,
  }) {
    if (rows.isEmpty) return [];
    final numberFormat = NumberFormat('#,##0.00', 'en_US');
    final intFormat = NumberFormat('#,##0', 'en_US');
    return [
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
                      numberFormat.format(r.amount),
                      numberFormat.format(r.quantity),
                      intFormat.format(r.count),
                    ]
                  : [
                      r.label,
                      numberFormat.format(r.amount),
                      intFormat.format(r.count),
                    ],
            )
            .toList(growable: false),
      ),
    ];
  }
}
