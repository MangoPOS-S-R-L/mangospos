// Conduce de salida de inventario — versión documento (PDF, A4 por defecto).
//
// Es la hoja que se archiva o se firma en oficina: las mermas (rotura,
// vencido, limpieza, faltante, donación) de la pantalla Salidas / Mermas, con
// motivo, cantidad y costo de cada una, y las MISMAS dos firmas que el conduce
// térmico (`waste_exit_ticket.dart`): «Entregado por» y «Autorizado por».
//
// Sirve para UNA salida (el ícono de imprimir de cada movimiento) o para
// VARIAS (el botón "Imprimir A4" de la pantalla): la tabla es la misma.

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/currency/business_currency.dart';
import '../../core/printing/os_print_dialog.dart';

/// Una salida del conduce.
class WasteExitPdfLine {
  final DateTime date;
  final String itemName;
  final double quantity;
  final String unit;
  final String reason;
  final String notes;
  final double costPerUnit;

  /// Área de un consumo interno (Baños, Cocina…). Vacía en las demás.
  final String destination;

  const WasteExitPdfLine({
    required this.date,
    required this.itemName,
    required this.quantity,
    required this.unit,
    required this.reason,
    this.notes = '',
    this.costPerUnit = 0,
    this.destination = '',
  });

  double get totalCost => quantity * costPerUnit;

  /// La columna de notas, con el área delante si la hay.
  String get notesWithDestination {
    final area = destination.trim();
    if (area.isEmpty) return notes;
    return notes.trim().isEmpty ? 'Para $area' : 'Para $area · $notes';
  }
}

class WasteExitPdf {
  const WasteExitPdf._();

  static String fileName(DateTime now) =>
      'salidas_inventario_${now.year}${_two(now.month)}${_two(now.day)}_'
      '${_two(now.hour)}${_two(now.minute)}.pdf';

  static Future<Uint8List> build({
    required List<WasteExitPdfLine> lines,
    required String businessName,
    required String warehouseName,
    String? operatorName,
    BusinessCurrency? currency,
    DateTime? printedAt,
    /// A4 por defecto (pedido del dueño). Al imprimir manda lo que se elija
    /// en el diálogo del sistema; la tabla usa anchos proporcionales.
    PdfPageFormat pageFormat = PdfPageFormat.a4,
  }) async {
    final money = currency ?? BusinessCurrency.fallbackDop;
    final now = printedAt ?? DateTime.now();
    final total = lines.fold<double>(0, (sum, l) => sum + l.totalCost);
    final doc = pw.Document();

    doc.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 28),
        build: (context) => [
          if (businessName.trim().isNotEmpty)
            pw.Center(
              child: pw.Text(
                _safe(businessName.trim().toUpperCase()),
                style: pw.TextStyle(
                  fontSize: 15,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
          pw.SizedBox(height: 10),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                lines.length == 1
                    ? 'CONDUCE DE SALIDA DE INVENTARIO'
                    : 'CONDUCE DE SALIDAS DE INVENTARIO',
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    'Bodega: ${_safe(warehouseName)}',
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                  pw.Text(
                    'Impreso: ${_dateTime(now)}',
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 4),
          _rule(),
          pw.SizedBox(height: 6),
          _table(lines, money),
          pw.SizedBox(height: 6),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              'Costo total: ${money.formatAmount(total)}',
              style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
          pw.SizedBox(height: 60),
          _signatures(operatorName ?? ''),
        ],
      ),
    );

    return doc.save();
  }

  /// Abre el diálogo de impresión del sistema, arrancando en A4.
  static Future<void> printDocument({
    required List<WasteExitPdfLine> lines,
    required String businessName,
    required String warehouseName,
    String? operatorName,
    BusinessCurrency? currency,
  }) async {
    final now = DateTime.now();
    await printWithOsDialog(
      format: PdfPageFormat.a4,
      name: fileName(now),
      onLayout: (format) => build(
        lines: lines,
        businessName: businessName,
        warehouseName: warehouseName,
        operatorName: operatorName,
        currency: currency,
        printedAt: now,
        pageFormat: format,
      ),
    );
  }

  static pw.Widget _table(List<WasteExitPdfLine> lines, BusinessCurrency money) {
    const header = pw.TextStyle(fontSize: 8.5);
    final bold = pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold);
    const cell = pw.TextStyle(fontSize: 8.5);

    pw.Widget th(String text, {bool right = false}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 4),
      child: pw.Text(
        text,
        style: bold,
        textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
      ),
    );
    pw.Widget td(String text, {bool right = false}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      child: pw.Text(
        text,
        style: cell,
        textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
      ),
    );

    return pw.Table(
      columnWidths: const {
        0: pw.FlexColumnWidth(1.6),
        1: pw.FlexColumnWidth(3.2),
        2: pw.FlexColumnWidth(1.4),
        3: pw.FlexColumnWidth(1.8),
        4: pw.FlexColumnWidth(2.6),
        5: pw.FlexColumnWidth(1.6),
      },
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(width: 0.3, color: PdfColors.grey500),
        bottom: pw.BorderSide(width: 0.7),
        top: pw.BorderSide(width: 0.7),
      ),
      children: [
        pw.TableRow(
          children: [
            th('Fecha'),
            th('Insumo'),
            th('Cantidad', right: true),
            th('Motivo'),
            th('Nota'),
            th('Costo', right: true),
          ],
        ),
        for (final l in lines)
          pw.TableRow(
            children: [
              td(_dateTime(l.date)),
              td(_safe(l.itemName)),
              td('${_qty(l.quantity)} ${l.unit}', right: true),
              td(_safe(l.reason)),
              td(_safe(l.notesWithDestination)),
              td(money.formatAmount(l.totalCost), right: true),
            ],
          ),
        if (lines.isEmpty)
          pw.TableRow(
            children: [
              td(''),
              pw.Padding(
                padding: const pw.EdgeInsets.all(6),
                child: pw.Text('Sin salidas.', style: header),
              ),
              td(''),
              td(''),
              td(''),
              td(''),
            ],
          ),
      ],
    );
  }

  static pw.Widget _signatures(String operatorName) {
    pw.Widget slot(String label, String name) => pw.Expanded(
      child: pw.Column(
        children: [
          pw.Container(height: 0.7, width: 190, color: PdfColors.black),
          pw.SizedBox(height: 3),
          pw.Text(label, style: const pw.TextStyle(fontSize: 9)),
          if (name.trim().isNotEmpty)
            pw.Text(
              _safe(name.toUpperCase()),
              style: const pw.TextStyle(fontSize: 8),
            ),
        ],
      ),
    );

    // Las mismas dos firmas que el conduce térmico: quien la saca de la
    // bodega y quien la autoriza.
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
      children: [
        slot('Entregado por', operatorName),
        slot('Autorizado por', ''),
      ],
    );
  }

  static pw.Widget _rule() =>
      pw.Container(height: 0.7, color: PdfColors.black);

  static String _qty(double value) {
    if ((value - value.roundToDouble()).abs() < 0.001) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(2);
  }

  /// La fuente base del PDF (Helvetica, WinAnsi) no tiene glifos más allá de
  /// Latin-1 y el `pdf` LANZA al encontrarlos. Las notas las escribe el
  /// usuario (rayas largas, emojis…): se cambian las rayas por guiones y se
  /// descarta lo demás, para que una nota rara nunca tumbe la impresión.
  static String _safe(String value) {
    final replaced = value
        .replaceAll('—', '-')
        .replaceAll('–', '-')
        .replaceAll('…', '...')
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .replaceAll('‘', "'")
        .replaceAll('’', "'");
    return String.fromCharCodes(replaced.runes.where((r) => r <= 0xFF));
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _dateTime(DateTime dt) =>
      '${_two(dt.day)}/${_two(dt.month)}/${dt.year} '
      '${_two(dt.hour)}:${_two(dt.minute)}';
}
