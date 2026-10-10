// La hoja de cierre dice desde cuándo estuvo abierta la caja. Una caja puede
// quedar abierta varios días, y con solo la fecha de impresión no se sabía qué
// periodo cubría el arqueo.

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mangopos/presentation/cashier/services/print_service.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('es_DO');
  });

  final service = CashClosePrintService(
    SupabaseClient('https://example.supabase.co', 'anon-key'),
  );

  const input = CashCloseInput(
    expectedCash: 12500,
    expectedCard: 0,
    expectedTransfer: 0,
    totalSales: 12500,
    transactionCount: 10,
    businessName: 'La Esquina',
  );

  const result = CashCloseResult(
    totalCounted: 12500,
    numericCard: 0,
    numericTransfer: 0,
    totalReported: 12500,
    expectedTotal: 12500,
    cashDifference: 0,
    cardDifference: 0,
    transferDifference: 0,
    totalDifference: 0,
  );

  // Instantes UTC: el ticket los muestra en hora de República Dominicana
  // (UTC-4). Apertura 04/10 08:15 RD, cierre 05/10 02:26 RD.
  final openedAt = DateTime.utc(2026, 10, 4, 12, 15);
  final closedAt = DateTime.utc(2026, 10, 5, 6, 26);
  final printedAt = DateTime.utc(2026, 10, 5, 7, 0);

  String ticket({
    DateTime? opened,
    DateTime? closed,
    int paperWidth = 80,
  }) => service
      .buildEscPos(
        input: input,
        result: result,
        denominations: const [],
        printedAt: printedAt,
        openedAt: opened,
        closedAt: closed,
        paperWidth: paperWidth,
      )
      .plainText;

  test('con la apertura, el encabezado dice apertura y cierre', () {
    final text = ticket(opened: openedAt, closed: closedAt);

    expect(text, contains('Apertura: 04/10/2026 08:15'));
    expect(text, contains('Cierre: 05/10/2026 02:26'));
    expect(text, isNot(contains('Fecha:')));
  });

  test('cierre aún sin sincronizar: usa la hora de impresión', () {
    final text = ticket(opened: openedAt);

    expect(text, contains('Apertura: 04/10/2026 08:15'));
    expect(text, contains('Cierre: 05/10/2026 03:00'));
  });

  test('sin la apertura el encabezado queda como siempre', () {
    final text = ticket();

    expect(text, contains('Fecha: 05/10/2026'));
    expect(text, contains('Hora: 03:00'));
    expect(text, isNot(contains('Apertura:')));
  });

  test('en papel de 58mm las líneas de apertura y cierre caben', () {
    final lines = ticket(opened: openedAt, closed: closedAt, paperWidth: 58)
        .split('\n')
        .where((l) => l.contains('Apertura:') || l.contains('Cierre:'));

    expect(lines, hasLength(2));
    for (final line in lines) {
      expect(line.trimRight().length, lessThanOrEqualTo(32), reason: line);
    }
  });
}
