import 'dart:typed_data';

import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CashClosePrintService {
  final SupabaseClient _client;
  final PrintingRepository _printingRepository;

  CashClosePrintService(SupabaseClient client)
      : _client = client,
        _printingRepository = PrintingRepository(client);

  Future<void> printCloseTicket({
    required CashCloseInput input,
    required CashCloseResult result,
    required List<DenominationCount> denominations,
    required DateTime printedAt,
  }) async {
    final bytes = _buildEscPos(
      input: input,
      result: result,
      denominations: denominations,
      printedAt: printedAt,
    );

    final printed = await _tryThermalPrint(bytes);
    if (printed) return;

    final pdf = await _buildPdf(
      input: input,
      result: result,
      denominations: denominations,
      printedAt: printedAt,
    );

    await Printing.layoutPdf(onLayout: (_) async => pdf);
  }

  List<int> _buildEscPos({
    required CashCloseInput input,
    required CashCloseResult result,
    required List<DenominationCount> denominations,
    required DateTime printedAt,
  }) {
    final gen = EscPosGenerator(paperWidth: 80);
    gen.initialize();
    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered(input.businessName);
    gen.setTextSize();
    gen.setBold(false);
    gen.textCentered('CIERRE DE CAJA');
    gen.textCentered('Fecha: ${formatDateEsDo(printedAt)}');
    gen.textCentered('Hora: ${formatTimeEsDo(printedAt)}');
    gen.doubleSeparator();

    gen.setBold(true);
    gen.text('CONTEO DE EFECTIVO');
    gen.setBold(false);
    for (final d in denominations.where((e) => e.count > 0)) {
      gen.textRow(
        '${formatRD(d.value)} x ${d.count}',
        formatRD(d.subtotal),
      );
    }
    gen.separator();
    gen.textRow('Total efectivo', formatRD(result.totalCounted));
    gen.doubleSeparator();

    gen.setBold(true);
    gen.text('COMPARACION');
    gen.setBold(false);
    gen.text('Concepto   Esperado   Reportado   Dif.');
    gen.separator();

    void row(String concept, int expected, int reported) {
      final diff = reported - expected;
      final diffLabel = '${diff >= 0 ? '+' : '-'}${formatRD(diff.abs()).replaceFirst('RD\$ ', '')}';
      final line =
          '${concept.padRight(10)} ${_shortMoney(expected).padLeft(8)} ${_shortMoney(reported).padLeft(9)} ${diffLabel.padLeft(8)}';
      gen.text(line);
    }

    row('Efectivo', input.expectedCash, result.totalCounted);
    row('Tarjetas', input.expectedCard, result.numericCard);
    row('Transf.', input.expectedTransfer, result.numericTransfer);
    row('TOTAL', result.expectedTotal, result.totalReported);
    gen.doubleSeparator();

    gen.textRow('TOTAL ESPERADO', formatRD(result.expectedTotal));
    gen.textRow('TOTAL REPORTADO', formatRD(result.totalReported));
    gen.separator();

    if (result.isBalanced) {
      gen.textCentered('✓ CAJA CUADRADA');
    } else if (result.hasSurplus) {
      gen.textCentered('SOBRANTE: ${formatRD(result.difference.abs())}');
    } else {
      gen.textCentered('FALTANTE: ${formatRD(result.difference.abs())}');
    }

    gen.doubleSeparator();
    gen.setBold(true);
    gen.text('ESTADISTICAS DEL TURNO');
    gen.setBold(false);
    gen.textRow('Total Ventas', formatRD(input.totalSales));
    gen.textRow('Transacciones', input.transactionCount.toString());
    gen.doubleSeparator();
    gen.text('Cajero: ${input.cashierName}');
    gen.text('Impreso: ${formatDateEsDo(printedAt)} ${formatTimeEsDo(printedAt)}');
    gen.textCentered('www.mangopos.do');
    gen.lineFeed(2);
    gen.cut();
    return gen.getCommands();
  }

  Future<bool> _tryThermalPrint(List<int> bytes) async {
    try {
      final businessId = await resolveBusinessIdOrNull(_client, 'auto');
      if (businessId == null) return false;

      final printers = await _printingRepository.getPrinters(businessId);
      if (printers.isEmpty) return false;

      final selected = printers
          .where((p) => (p.ipAddress?.isNotEmpty ?? false) && p.isActive)
          .toList(growable: false);
      final printer = selected.isNotEmpty
          ? selected.first
          : printers.firstWhere(
              (p) => p.ipAddress?.isNotEmpty ?? false,
              orElse: () => printers.first,
            );

      final ip = printer.ipAddress;
      if (ip == null || ip.isEmpty) return false;
      final port = printer.port ?? 9100;

      if (await _printingRepository.isAgentUp()) {
        await _printingRepository.printRawViaAgent(ip: ip, port: port, data: bytes);
      } else {
        await _printingRepository.printRawDirectTcp(ip: ip, port: port, data: bytes);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List> _buildPdf({
    required CashCloseInput input,
    required CashCloseResult result,
    required List<DenominationCount> denominations,
    required DateTime printedAt,
  }) async {
    final doc = pw.Document();
    final mono = pw.Font.courier();
    final base = pw.TextStyle(font: mono, fontSize: 10);
    final bold = pw.TextStyle(font: mono, fontSize: 10, fontWeight: pw.FontWeight.bold);

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(80 * PdfPageFormat.mm, 400 * PdfPageFormat.mm, marginAll: 4 * PdfPageFormat.mm),
        build: (context) {
          pw.Widget line(String l, {pw.TextStyle? style, pw.TextAlign align = pw.TextAlign.left}) {
            return pw.Text(l, style: style ?? base, textAlign: align);
          }

          final denoLines = denominations
              .where((d) => d.count > 0)
              .map((d) => '${formatRD(d.value)} x ${d.count}    ${formatRD(d.subtotal)}')
              .toList();

          final statusLine = result.isBalanced
              ? '✓ CAJA CUADRADA'
              : (result.hasSurplus
                  ? 'SOBRANTE: ${formatRD(result.difference.abs())}'
                  : 'FALTANTE: ${formatRD(result.difference.abs())}');

          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              line(input.businessName, style: bold, align: pw.TextAlign.center),
              line('CIERRE DE CAJA', style: bold, align: pw.TextAlign.center),
              line('${formatDateEsDo(printedAt)} ${formatTimeEsDo(printedAt)}', align: pw.TextAlign.center),
              line('--------------------------------'),
              line('CONTEO DE EFECTIVO', style: bold),
              ...denoLines.map((e) => line(e)),
              line('Total efectivo: ${formatRD(result.totalCounted)}', style: bold),
              line('--------------------------------'),
              line('COMPARACION', style: bold),
              line('Efectivo     ${formatRD(input.expectedCash)} / ${formatRD(result.totalCounted)}'),
              line('Tarjetas     ${formatRD(input.expectedCard)} / ${formatRD(result.numericCard)}'),
              line('Transfer.    ${formatRD(input.expectedTransfer)} / ${formatRD(result.numericTransfer)}'),
              line('TOTAL        ${formatRD(result.expectedTotal)} / ${formatRD(result.totalReported)}', style: bold),
              line('--------------------------------'),
              line('TOTAL ESPERADO: ${formatRD(result.expectedTotal)}'),
              line('TOTAL REPORTADO: ${formatRD(result.totalReported)}'),
              line(statusLine, style: bold, align: pw.TextAlign.center),
              line('--------------------------------'),
              line('ESTADISTICAS DEL TURNO', style: bold),
              line('Total Ventas: ${formatRD(input.totalSales)}'),
              line('Transacciones: ${input.transactionCount}'),
              line('--------------------------------'),
              line('Cajero: ${input.cashierName}'),
              line('Impreso: ${formatDateEsDo(printedAt)} ${formatTimeEsDo(printedAt)}'),
              line('www.mangopos.do', align: pw.TextAlign.center),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  String _shortMoney(int amount) {
    final full = formatRD(amount).replaceFirst('RD\$ ', '');
    return full;
  }
}
