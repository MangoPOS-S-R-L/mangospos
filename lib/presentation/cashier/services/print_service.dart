import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';
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

    await _printThermalOrThrow(bytes);
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
      gen.textRow('${formatRD(d.value)} x ${d.count}', formatRD(d.subtotal));
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
      final diffLabel =
          '${diff >= 0 ? '+' : '-'}${formatRD(diff.abs()).replaceFirst('RD\$ ', '')}';
      final line =
          '${concept.padRight(10)} ${_shortMoney(expected).padLeft(8)} ${_shortMoney(reported).padLeft(9)} ${diffLabel.padLeft(8)}';
      gen.text(line);
    }

    row('Efectivo', input.expectedCash, result.totalCounted);
    row('Tarjetas', input.expectedCard, result.numericCard);
    row('Transf.', input.expectedTransfer, result.numericTransfer);
    row('CIERRE', input.expectedClosureAmount, result.totalCounted);
    row('TOTAL', input.expectedTotal, result.totalReported);
    gen.doubleSeparator();

    gen.textRow('CIERRE ESPERADO', formatRD(input.expectedClosureAmount));
    gen.textRow('CIERRE REPORTADO', formatRD(result.totalCounted));
    gen.textRow('TOTAL ESPERADO', formatRD(input.expectedTotal));
    gen.textRow('TOTAL REPORTADO', formatRD(result.totalReported));
    gen.separator();

    if (result.isBalanced) {
      gen.textCentered('CAJA CUADRADA');
    } else if (result.hasSurplus) {
      gen.textCentered('SOBRANTE: ${formatRD(result.totalDifference.abs())}');
    } else {
      gen.textCentered('FALTANTE: ${formatRD(result.totalDifference.abs())}');
    }

    gen.doubleSeparator();
    gen.setBold(true);
    gen.text('ESTADISTICAS DEL TURNO');
    gen.setBold(false);
    gen.textRow('Total Ventas', formatRD(input.totalSales));
    gen.textRow('Transacciones', input.transactionCount.toString());
    gen.doubleSeparator();
    gen.text('Cajero: ${input.cashierName}');
    gen.text(
      'Impreso: ${formatDateEsDo(printedAt)} ${formatTimeEsDo(printedAt)}',
    );
    gen.textCentered('www.mangopos.do');
    gen.lineFeed(2);
    gen.cut();
    return gen.getCommands();
  }

  Future<void> _printThermalOrThrow(List<int> bytes) async {
    final businessId = await resolveBusinessIdOrNull(_client, 'auto');
    if (businessId == null) {
      throw Exception(
        'No se pudo resolver el negocio activo para imprimir el cierre.',
      );
    }

    final preferredPrinter = await _printingRepository
        .getAssignedPrinterForType(
          businessId: businessId,
          preferredAreaCodes: const [
            'cashier',
            'receipt',
            'receipts',
            'fiscal',
          ],
          printsReceipts: true,
        );

    final printers = await _printingRepository.getPrinters(businessId);
    final activePrinters = printers
        .where((p) => p.isActive)
        .toList(growable: false);

    final printer = preferredPrinter != null && preferredPrinter.isActive
        ? preferredPrinter
        : (activePrinters.isNotEmpty ? activePrinters.first : null);

    if (printer == null) {
      throw Exception(
        'No hay una impresora activa configurada para imprimir el cierre de caja.',
      );
    }

    await _printingRepository.printEscPos(printer: printer, data: bytes);
  }

  String _shortMoney(int amount) {
    return formatRD(amount).replaceFirst('RD\$ ', '');
  }
}
