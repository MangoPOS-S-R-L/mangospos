// Exportación a PDF del reporte "Ventas por mesero": tabla resumen por
// empleado + desglose de productos vendidos por cada uno. Sigue el mismo
// patrón que ReportsExportService (pdf + Printing.sharePdf).

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'package:mangopos/data/repositories/sales_by_waiter_repository.dart';

class SalesByWaiterExportService {
  static Future<void> exportPdf({
    required List<WaiterSalesRow> rows,
    required List<WaiterProductRow> productRows,
    required DateTime from,
    required DateTime to,
    required NumberFormat currency,
    String? productSearch,
  }) async {
    final pdf = pw.Document();
    final dateFormat = DateFormat('dd/MM/yyyy');
    final intFormat = NumberFormat('#,##0', 'en_US');
    final qtyFormat = NumberFormat('#,##0.##', 'en_US');
    final search = productSearch?.trim() ?? '';

    final totalGross = rows.fold<double>(0, (s, r) => s + r.grossAmount);
    final totalDiscounts = rows.fold<double>(
      0,
      (s, r) => s + r.discountsAmount,
    );
    final totalNet = rows.fold<double>(0, (s, r) => s + r.netAmount);
    final totalItems = rows.fold<int>(0, (s, r) => s + r.itemsCount);

    // Desglose agrupado por empleado, en el mismo orden del resumen
    // (neto desc). Productos sin fila resumen no deberían existir porque
    // ambas RPC comparten filtros, pero si aparecen van al final.
    final byEmployee = <String, List<WaiterProductRow>>{};
    for (final p in productRows) {
      byEmployee.putIfAbsent(p.employeeId, () => []).add(p);
    }
    final orderedEmployeeIds = <String>[
      ...rows.map((r) => r.employeeId).where(byEmployee.containsKey),
      ...byEmployee.keys.where((id) => !rows.any((r) => r.employeeId == id)),
    ];

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        maxPages: 500,
        margin: const pw.EdgeInsets.all(24),
        build: (context) => [
          pw.Text(
            'Ventas por mesero',
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Rango: ${dateFormat.format(from)} - ${dateFormat.format(to)}',
          ),
          if (search.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text('Filtro de producto: "$search"'),
          ],
          pw.SizedBox(height: 16),
          pw.Text(
            'Resumen por mesero',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.TableHelper.fromTextArray(
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
            ),
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerDecoration: pw.BoxDecoration(
              color: PdfColor.fromHex('#E5E7EB'),
            ),
            headers: const [
              'Mesero',
              'Órdenes',
              'Items',
              'Bruto',
              'Descuentos',
              'Neto',
            ],
            data: [
              ...rows.map(
                (r) => [
                  r.employeeName.isNotEmpty ? r.employeeName : 'Sin mesero',
                  intFormat.format(r.ordersCount),
                  intFormat.format(r.itemsCount),
                  currency.format(r.grossAmount),
                  currency.format(r.discountsAmount),
                  currency.format(r.netAmount),
                ],
              ),
              [
                'Total',
                '',
                intFormat.format(totalItems),
                currency.format(totalGross),
                currency.format(totalDiscounts),
                currency.format(totalNet),
              ],
            ],
          ),
          if (orderedEmployeeIds.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            pw.Text(
              'Desglose de productos por mesero',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
          ],
          for (final empId in orderedEmployeeIds) ...[
            pw.SizedBox(height: 12),
            pw.Text(
              byEmployee[empId]!.first.employeeName.isNotEmpty
                  ? byEmployee[empId]!.first.employeeName
                  : 'Sin mesero',
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 4),
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
              ),
              cellStyle: const pw.TextStyle(fontSize: 8),
              headerDecoration: pw.BoxDecoration(
                color: PdfColor.fromHex('#F3F4F6'),
              ),
              headers: const [
                'Producto',
                'Cant.',
                'Bruto',
                'Descuentos',
                'Neto',
              ],
              data: byEmployee[empId]!
                  .map(
                    (p) => [
                      p.sku.isNotEmpty
                          ? '${p.productName} (${p.sku})'
                          : p.productName,
                      qtyFormat.format(p.units),
                      currency.format(p.grossAmount),
                      currency.format(p.discountsAmount),
                      currency.format(p.netAmount),
                    ],
                  )
                  .toList(growable: false),
            ),
          ],
        ],
      ),
    );

    final filename =
        'ventas_por_mesero_${DateTime.now().millisecondsSinceEpoch}.pdf';
    await Printing.sharePdf(bytes: await pdf.save(), filename: filename);
  }
}
