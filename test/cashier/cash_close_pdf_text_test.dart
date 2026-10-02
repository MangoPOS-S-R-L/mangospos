// El botón "PDF" del cierre arma el texto con `buildCloseTicketText`, que NO
// pasa por la térmica. Tiene que salir el mismo ticket de 80mm que imprime
// `printCloseTicket`, o el PDF y el papel dirían cosas distintas.

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mangopos/presentation/cashier/services/print_service.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('es_DO');
  });

  // Sin sesión no se consultan las secciones opcionales: el cliente es solo
  // para satisfacer el constructor del servicio.
  final service = CashClosePrintService(
    SupabaseClient('https://example.supabase.co', 'anon-key'),
  );

  final input = CashCloseInput(
    expectedCash: 12500,
    expectedCard: 8300,
    expectedTransfer: 2200,
    totalSales: 23000,
    transactionCount: 47,
    cashierName: 'Juana Martínez',
    businessName: 'La Esquina',
    startAmount: 2000,
  );

  const result = CashCloseResult(
    totalCounted: 12480,
    numericCard: 8300,
    numericTransfer: 2200,
    totalReported: 22980,
    expectedTotal: 23000,
    cashDifference: -20,
    cardDifference: 0,
    transferDifference: 0,
    totalDifference: -20,
  );

  const denominations = [
    DenominationCount(value: 2000, label: '2000', count: 5),
  ];
  final printedAt = DateTime(2026, 1, 1, 22, 30);

  test('el PDF trae el mismo ticket de 80mm que el papel', () async {
    final text = await service.buildCloseTicketText(
      input: input,
      result: result,
      denominations: denominations,
      printedAt: printedAt,
    );

    final paper = service.buildEscPos(
      input: input,
      result: result,
      denominations: denominations,
      printedAt: printedAt,
    );

    expect(text, paper.plainText);
    expect(text, contains('Concepto   Esperado   Reportado   Dif.'));
    expect(text, contains('Tarjetas'));
    expect(text, isNot(contains('REIMPRESION')));
  });

  test('el PDF de un cierre ya hecho va marcado como reimpresión', () async {
    final text = await service.buildCloseTicketText(
      input: input,
      result: result,
      denominations: denominations,
      printedAt: printedAt,
      reprint: true,
    );

    expect(text, contains('** REIMPRESION **'));
  });
}
