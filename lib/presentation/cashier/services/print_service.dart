import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:mangopos/data/models/printing.dart' show PrinterConfig;
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
    String? cashRegisterId,
  }) async {
    final bytes = _buildEscPos(
      input: input,
      result: result,
      denominations: denominations,
      printedAt: printedAt,
    );

    await _printThermalOrThrow(bytes, cashRegisterId: cashRegisterId);
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

    void row(String concept, num expected, num reported) {
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
    gen.textRow('MONTO INICIAL', formatRD(input.startAmount));
    final toDeposit = result.totalCounted - input.startAmount;
    gen.setBold(true);
    gen.textRow('MONTO A DEPOSITAR', formatRD(toDeposit));
    gen.setBold(false);
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

    // Sprint Caja Pro — Listado detallado de depósitos / retiros /
    // gastos del turno. Cada uno con razón y monto para auditoría
    // (entrega de dinero a contador, banco, etc.).
    if (input.movements.isNotEmpty) {
      _renderMovementsSection(
        gen,
        title: 'DEPOSITOS DEL TURNO',
        entries: input.movements.where((m) => m.type == 'deposit').toList(),
        sign: '+',
      );
      _renderMovementsSection(
        gen,
        title: 'RETIROS DEL TURNO',
        entries:
            input.movements.where((m) => m.type == 'withdrawal').toList(),
        sign: '-',
      );
      _renderMovementsSection(
        gen,
        title: 'GASTOS DEL TURNO',
        entries: input.movements.where((m) => m.type == 'expense').toList(),
        sign: '-',
      );
    }

    gen.text('Cajero: ${input.cashierName}');
    gen.text(
      'Impreso: ${formatDateEsDo(printedAt)} ${formatTimeEsDo(printedAt)}',
    );
    gen.lineFeed(3);
    gen.textCentered('__________________________');
    gen.textCentered('Firma Cajero');
    gen.lineFeed(3);
    gen.textCentered('__________________________');
    gen.textCentered('Recibe Conforme');
    gen.lineFeed(2);
    gen.textCentered('www.mangopos.do');
    gen.lineFeed(2);
    gen.cut();
    return gen.getCommands();
  }

  Future<void> _printThermalOrThrow(
    List<int> bytes, {
    String? cashRegisterId,
  }) async {
    final businessId = await resolveBusinessIdOrNull(_client, 'auto');
    if (businessId == null) {
      throw Exception(
        'No se pudo resolver el negocio activo para imprimir el cierre.',
      );
    }

    // 1. Try register-specific printer first
    PrinterConfig? registerPrinter;
    if (cashRegisterId != null) {
      final data = await _client
          .from('cash_registers')
          .select('receipt_printer_id')
          .eq('id', cashRegisterId)
          .maybeSingle();
      final printerId = data?['receipt_printer_id'] as String?;
      if (printerId != null) {
        registerPrinter = await _printingRepository.getPrinterById(printerId);
      }
    }

    // 2. Fall back to area-based lookup
    final preferredPrinter =
        registerPrinter ??
        await _printingRepository.getAssignedPrinterForType(
          businessId: businessId,
          preferredAreaCodes: const [
            'cash_close',
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

    // Para cierre de caja debe tener prioridad la impresora explícitamente
    // asignada al área de cierre, aunque el flag `online` no esté actualizado.
    final printer =
        preferredPrinter ??
        (activePrinters.isNotEmpty ? activePrinters.first : null);

    if (printer == null) {
      throw Exception(
        'No hay una impresora configurada para imprimir el cierre de caja.',
      );
    }

    if (kIsWeb && printer.isUSB && !await _printingRepository.isAgentUp()) {
      throw Exception(
        'El cierre está asignado a una impresora USB, pero este flujo necesita el Agente Local activo en la PC donde está conectada.',
      );
    }

    await _printingRepository.printEscPos(printer: printer, data: bytes);
  }

  String _shortMoney(num amount) {
    return formatRD(amount).replaceFirst('RD\$ ', '');
  }

  /// Sprint Caja Pro — Renderiza una sección de movimientos manuales
  /// del turno (depósitos, retiros o gastos) con razón + monto + total.
  /// Si no hay entradas la sección se omite por completo.
  void _renderMovementsSection(
    EscPosGenerator gen, {
    required String title,
    required List<CashMovementEntry> entries,
    required String sign,
  }) {
    if (entries.isEmpty) return;
    gen.setBold(true);
    gen.text(title);
    gen.setBold(false);
    var total = 0.0;
    for (final m in entries) {
      total += m.amount;
      final label =
          (m.reasonLabel?.trim().isNotEmpty == true ? m.reasonLabel!.trim() : '—');
      // Línea con razón a la izquierda + monto con signo a la derecha.
      // 28 chars máximo en el label para no romper papel de 80mm.
      final shortLabel = label.length > 28 ? '${label.substring(0, 25)}...' : label;
      gen.textRow(shortLabel, '$sign ${_shortMoney(m.amount)}');
    }
    gen.separator();
    gen.setBold(true);
    gen.textRow('Subtotal $title', '$sign ${formatRD(total)}');
    gen.setBold(false);
    gen.doubleSeparator();
  }
}
