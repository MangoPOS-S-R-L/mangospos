// Conduce de recepción de mercancía — versión documento (PDF carta).
//
// Es el papel que archiva contabilidad: una hoja por recepción, con el
// encabezado del negocio, el suplidor, la tabla de lo recibido y las dos
// firmas. Sale por cualquier impresora normal (Printing.layoutPdf abre el
// diálogo nativo) o se comparte como archivo.
//
// Lee el MISMO [GoodsReceipt] que el ticket térmico (goods_receipt_ticket.dart):
// el papel del almacén y el del contable no pueden decir cosas distintas.

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/currency/business_currency.dart';
import '../../presentation/purchases/state/goods_receipt.dart';

class GoodsReceiptPdf {
  const GoodsReceiptPdf._();

  /// Nombre de archivo sugerido al compartir/guardar.
  static String fileName(GoodsReceipt receipt) {
    final shortId =
        receipt.id.length > 8 ? receipt.id.substring(0, 8) : receipt.id;
    final number = receipt.number.isEmpty ? shortId : receipt.number;
    return 'conduce_$number.pdf';
  }

  static Future<Uint8List> build({
    required GoodsReceipt receipt,
    required String businessName,
    String? businessBranch,
    String? businessAddress,
    String? businessPhone,
    String? businessRnc,
    BusinessCurrency? currency,
    bool isReprint = false,
  }) async {
    final money = currency ?? BusinessCurrency.fallbackDop;
    final doc = pw.Document();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 28),
        build: (context) => [
          _header(
            businessName: businessName,
            businessBranch: businessBranch,
            businessAddress: businessAddress,
            businessPhone: businessPhone,
            businessRnc: businessRnc,
          ),
          pw.SizedBox(height: 10),
          _documentBar(receipt, isReprint: isReprint),
          pw.SizedBox(height: 8),
          _supplierBar(receipt),
          pw.SizedBox(height: 6),
          _linesTable(receipt, money),
          pw.SizedBox(height: 4),
          _totals(receipt, money),
          if (receipt.notes.trim().isNotEmpty) ...[
            pw.SizedBox(height: 14),
            pw.Text(
              'Observaciones',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 2),
            pw.Text(receipt.notes.trim(), style: const pw.TextStyle(fontSize: 9)),
          ],
          pw.SizedBox(height: 46),
          _signatures(receipt),
        ],
      ),
    );

    return doc.save();
  }

  /// Abre el diálogo de impresión nativo del sistema (cualquier impresora,
  /// no solo la térmica del POS). Es la ruta que usa el contable.
  static Future<void> printDocument({
    required GoodsReceipt receipt,
    required String businessName,
    String? businessBranch,
    String? businessAddress,
    String? businessPhone,
    String? businessRnc,
    BusinessCurrency? currency,
    bool isReprint = false,
  }) async {
    final bytes = await build(
      receipt: receipt,
      businessName: businessName,
      businessBranch: businessBranch,
      businessAddress: businessAddress,
      businessPhone: businessPhone,
      businessRnc: businessRnc,
      currency: currency,
      isReprint: isReprint,
    );
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: fileName(receipt),
    );
  }

  /// Comparte/guarda el PDF con el diálogo nativo del sistema.
  static Future<void> shareDocument({
    required GoodsReceipt receipt,
    required String businessName,
    String? businessBranch,
    String? businessAddress,
    String? businessPhone,
    String? businessRnc,
    BusinessCurrency? currency,
    bool isReprint = false,
  }) async {
    final bytes = await build(
      receipt: receipt,
      businessName: businessName,
      businessBranch: businessBranch,
      businessAddress: businessAddress,
      businessPhone: businessPhone,
      businessRnc: businessRnc,
      currency: currency,
      isReprint: isReprint,
    );
    await Printing.sharePdf(bytes: bytes, filename: fileName(receipt));
  }

  // ── Bloques ───────────────────────────────────────────────────────────────

  static pw.Widget _header({
    required String businessName,
    String? businessBranch,
    String? businessAddress,
    String? businessPhone,
    String? businessRnc,
  }) {
    final subtitle = <String>[
      if ((businessBranch ?? '').trim().isNotEmpty) businessBranch!.trim(),
      if ((businessAddress ?? '').trim().isNotEmpty) businessAddress!.trim(),
      if ((businessPhone ?? '').trim().isNotEmpty) 'TEL. ${businessPhone!.trim()}',
      if ((businessRnc ?? '').trim().isNotEmpty) 'RNC ${businessRnc!.trim()}',
    ];

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        if (businessName.trim().isNotEmpty)
          pw.Center(
            child: pw.Text(
              businessName.trim().toUpperCase(),
              style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
            ),
          ),
        for (final line in subtitle)
          pw.Center(
            child: pw.Text(
              line.toUpperCase(),
              style: const pw.TextStyle(fontSize: 8.5),
            ),
          ),
      ],
    );
  }

  /// Barra del documento: a la izquierda el tipo, a la derecha número y fecha.
  static pw.Widget _documentBar(GoodsReceipt receipt, {required bool isReprint}) {
    final labels = <String, String>{
      'No.:': receipt.number.isEmpty ? 's/n' : receipt.number,
      'Fecha:': _date(receipt.date),
      if (receipt.orderNumber.isNotEmpty) 'Orden:': receipt.orderNumber,
      if (receipt.invoiceNumber.isNotEmpty) 'Factura:': receipt.invoiceNumber,
      if (receipt.ncf.isNotEmpty) 'NCF:': receipt.ncf,
    };

    return pw.Column(
      children: [
        _rule(),
        pw.SizedBox(height: 4),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'RECEPCIÓN DE MERCANCÍA',
                    style: pw.TextStyle(
                      fontSize: 12,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    'Almacén: ${receipt.warehouseName}',
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                  // Una entrega parcial deja mercancía pendiente en la orden.
                  // Va en la cara del documento, no escondido en las líneas.
                  if (receipt.isPartial)
                    pw.Text(
                      'ENTREGA PARCIAL',
                      style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  if (isReprint)
                    pw.Text(
                      'REIMPRESIÓN',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  // Reconstruido desde la orden: no hubo recepción registrada.
                  // Va visible, no en letra chica al pie.
                  if (receipt.isReconstructed)
                    pw.Text(
                      'Sin recepción registrada — reconstruido de la orden',
                      style: const pw.TextStyle(fontSize: 8.5),
                    ),
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                for (final entry in labels.entries)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 1),
                    child: pw.Row(
                      children: [
                        pw.SizedBox(
                          width: 52,
                          child: pw.Text(
                            entry.key,
                            style: const pw.TextStyle(fontSize: 9),
                          ),
                        ),
                        pw.Text(
                          entry.value,
                          style: pw.TextStyle(
                            fontSize: 9,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 4),
        _rule(),
      ],
    );
  }

  static pw.Widget _supplierBar(GoodsReceipt receipt) {
    final rnc = receipt.supplierRnc.trim();
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Expanded(
          child: pw.RichText(
            text: pw.TextSpan(
              children: [
                const pw.TextSpan(
                  text: 'Suplidor:  ',
                  style: pw.TextStyle(fontSize: 9.5),
                ),
                pw.TextSpan(
                  text: receipt.supplierName.toUpperCase(),
                  style: pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                if (rnc.isNotEmpty)
                  pw.TextSpan(
                    text: '   RNC: $rnc',
                    style: const pw.TextStyle(fontSize: 9),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static pw.Widget _linesTable(GoodsReceipt receipt, BusinessCurrency money) {
    const headerStyle = pw.TextStyle(fontSize: 8.5);
    const cellStyle = pw.TextStyle(fontSize: 9);

    pw.Widget cell(String value, {pw.TextAlign align = pw.TextAlign.left}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2.5, horizontal: 2),
          child: pw.Text(value, style: cellStyle, textAlign: align),
        );

    return pw.Table(
      columnWidths: const {
        0: pw.FlexColumnWidth(1.5),   // Código
        1: pw.FlexColumnWidth(1.2),   // Cantidad
        2: pw.FlexColumnWidth(1.6),   // Referencia
        3: pw.FlexColumnWidth(5.0),   // Descripción
        4: pw.FlexColumnWidth(1.6),   // Costo
        5: pw.FlexColumnWidth(1.8),   // Importe
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(
            border: pw.Border(
              top: pw.BorderSide(width: 0.7),
              bottom: pw.BorderSide(width: 0.7),
            ),
          ),
          children: [
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 2),
              child: pw.Text('Código', style: headerStyle),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 2),
              child: pw.Text('Cantidad', style: headerStyle),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 2),
              child: pw.Text('Referencia', style: headerStyle),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 2),
              child: pw.Text('Descripción', style: headerStyle),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 2),
              child: pw.Text(
                'Costo',
                style: headerStyle,
                textAlign: pw.TextAlign.right,
              ),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 2),
              child: pw.Text(
                'Importe',
                style: headerStyle,
                textAlign: pw.TextAlign.right,
              ),
            ),
          ],
        ),
        for (final line in receipt.lines)
          pw.TableRow(
            children: [
              cell(line.code),
              cell('${_qty(line.quantity)} ${line.unit}'),
              cell(line.reference),
              cell(line.description),
              cell(
                money.formatAmount(line.unitCost),
                align: pw.TextAlign.right,
              ),
              cell(money.formatAmount(line.amount), align: pw.TextAlign.right),
            ],
          ),
      ],
    );
  }

  static pw.Widget _totals(GoodsReceipt receipt, BusinessCurrency money) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        _rule(),
        pw.SizedBox(height: 3),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              '${receipt.lines.length} renglones · '
              '${_qty(receipt.totalUnits)} unidades recibidas',
              style: const pw.TextStyle(fontSize: 9),
            ),
            pw.Row(
              children: [
                pw.Text(
                  'Total ${money.code}:  ',
                  style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
                ),
                pw.Text(
                  money.formatAmount(receipt.total),
                  style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 3),
        _rule(),
      ],
    );
  }

  static pw.Widget _signatures(GoodsReceipt receipt) {
    pw.Widget slot(String label, String name) => pw.Expanded(
          child: pw.Column(
            children: [
              pw.Container(
                height: 0.7,
                width: 190,
                color: PdfColors.black,
              ),
              pw.SizedBox(height: 3),
              pw.Text(label, style: const pw.TextStyle(fontSize: 9)),
              if (name.trim().isNotEmpty)
                pw.Text(
                  name.toUpperCase(),
                  style: const pw.TextStyle(fontSize: 8),
                ),
            ],
          ),
        );

    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
      children: [
        slot('Entregado por', ''),
        slot('Recibido por', receipt.receivedByName),
      ],
    );
  }

  static pw.Widget _rule() =>
      pw.Container(height: 0.7, color: PdfColors.black);

  static String _qty(double value) {
    if ((value - value.roundToDouble()).abs() < 0.001) {
      return value.toStringAsFixed(0);
    }
    if ((value * 10 - (value * 10).roundToDouble()).abs() < 0.001) {
      return value.toStringAsFixed(1);
    }
    return value.toStringAsFixed(2);
  }

  static String _date(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/'
      '${dt.month.toString().padLeft(2, '0')}/${dt.year}';
}
