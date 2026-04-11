import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
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
      case ReportCategory.fiscal:
        return [
          _metricsTable(viewModel.getFiscalMetricCards()),
          pw.SizedBox(height: 16),
          _breakdownTable(
            'Comprobantes por tipo',
            viewModel.getFiscalTypeRows(),
          ),
          pw.SizedBox(height: 16),
          ..._fiscalDocumentsTable(viewModel.getFiscalDocuments()),
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

  static String _ncfTypeName(String type) {
    switch (type) {
      case 'B01':
      case 'E31':
        return 'Crédito Fiscal';
      case 'B02':
      case 'E32':
        return 'Consumo';
      case 'B03':
      case 'E33':
        return 'Nota de Débito';
      case 'B04':
      case 'E34':
        return 'Nota de Crédito';
      case 'B14':
      case 'E44':
        return 'Reg. Especiales';
      case 'B15':
      case 'E45':
        return 'Gubernamental';
      default:
        return type;
    }
  }

  static List<pw.Widget> _fiscalDocumentsTable(
    List<Map<String, dynamic>> documents,
  ) {
    if (documents.isEmpty) {
      return [
        pw.Text('No hay comprobantes fiscales en el rango seleccionado.'),
      ];
    }

    final dateFormat = DateFormat('dd/MM/yyyy');
    final numberFormat = NumberFormat('#,##0.00', 'es_DO');

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
        headerStyle: pw.TextStyle(
          fontWeight: pw.FontWeight.bold,
          fontSize: 8,
        ),
        cellStyle: const pw.TextStyle(fontSize: 7),
        headerDecoration: pw.BoxDecoration(
          color: PdfColor.fromHex('#E5E7EB'),
        ),
        headers: const [
          'NCF',
          'Tipo',
          'Cliente',
          'RNC/Cédula',
          'Subtotal',
          'ITBIS',
          'Total',
          'Estado',
          'Fecha',
        ],
        data: documents.map((doc) {
          final ncfNumber = doc['ncf_number']?.toString() ?? '';
          final ncfType = doc['ncf_type']?.toString() ?? '';
          final customerName =
              doc['customer_name']?.toString() ?? 'CONSUMIDOR FINAL';
          final customerRnc = doc['customer_rnc']?.toString() ?? '-';
          final subtotal = (doc['subtotal'] as num?)?.toDouble() ?? 0;
          final itbis = (doc['itbis_amount'] as num?)?.toDouble() ?? 0;
          final total = (doc['total'] as num?)?.toDouble() ?? 0;
          final status = doc['status']?.toString() ?? 'active';
          final issuedAt =
              DateTime.tryParse(doc['issued_at']?.toString() ?? '') ??
                  DateTime.now();

          return [
            ncfNumber,
            _ncfTypeName(ncfType),
            customerName.length > 25
                ? '${customerName.substring(0, 25)}...'
                : customerName,
            customerRnc.isEmpty ? '-' : customerRnc,
            numberFormat.format(subtotal),
            numberFormat.format(itbis),
            numberFormat.format(total),
            status == 'active' ? 'Activo' : 'Anulado',
            dateFormat.format(issuedAt.toLocal()),
          ];
        }).toList(growable: false),
      ),
    ];
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
