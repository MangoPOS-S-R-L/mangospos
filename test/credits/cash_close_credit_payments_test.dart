// El bloque "ABONOS A CREDITO" del ticket de cierre.
//
// Lo que se prueba acá no es cosmético: si la advertencia de que el efectivo
// YA está dentro de los depósitos se pierde, quien cuadra la caja lo suma
// otra vez y le sobra en el papel un dinero que no está en la gaveta.

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mangopos/presentation/cashier/services/print_service.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  // El pie del ticket formatea la fecha en es_DO.
  setUpAll(() => initializeDateFormatting('es_DO', null));

  // El builder no toca Supabase: el cliente es solo para el constructor.
  final service = CashClosePrintService(
    SupabaseClient('https://example.supabase.co', 'anon-key'),
  );

  const input = CashCloseInput(
    expectedCash: 12500,
    expectedCard: 8300,
    expectedTransfer: 2200,
    totalSales: 23000,
    transactionCount: 47,
    cashierName: 'Juana Martínez',
    businessName: 'Penda Express',
    startAmount: 2000,
    totalDeposits: 4500,
  );

  const result = CashCloseResult(
    totalCounted: 12500,
    numericCard: 8300,
    numericTransfer: 2200,
    totalReported: 23000,
    expectedTotal: 23000,
    cashDifference: 0,
    cardDifference: 0,
    transferDifference: 0,
    totalDifference: 0,
  );

  final creditPayments = {
    'total': 4500.0,
    'count': 2,
    'cash': 3000.0,
    'other': 1500.0,
    'by_method': const [],
    'payments': [
      {
        'code': 'AB-00001',
        'amount': 3000.0,
        'method_code': 'cash',
        'method_name': 'Efectivo',
        'customer_name': 'Colmado La Esquina',
        'created_at': '2026-09-02T18:00:00Z',
      },
      {
        'code': 'AB-00002',
        'amount': 1500.0,
        'method_code': 'transfer',
        'method_name': 'Transferencia',
        'customer_name': 'Bar Mediotiempo',
        'created_at': '2026-09-02T19:30:00Z',
      },
    ],
  };

  String build({
    Map<String, dynamic>? payments,
    int paperWidth = 80,
  }) {
    return service
        .buildEscPos(
          input: input,
          result: result,
          denominations: const [],
          printedAt: DateTime(2026, 9, 2, 22, 30),
          creditPayments: payments,
          paperWidth: paperWidth,
        )
        .plainText;
  }

  group('Bloque de abonos en el cierre', () {
    test('lista cada abono con su cliente, recibo y forma de pago', () {
      final text = build(payments: creditPayments);

      expect(text, contains('ABONOS A CREDITO'));
      expect(text, contains('Colmado La Esquina'));
      expect(text, contains('AB-00001'));
      expect(text, contains('Bar Mediotiempo'));
      expect(text, contains('AB-00002'));
      expect(text, contains('Transferencia'));
    });

    test('avisa que el efectivo ya está contado en los depósitos', () {
      final text = build(payments: creditPayments);

      expect(text, contains('Total abonos'));
      expect(text, contains('En efectivo'));
      expect(text, contains('ya incluido en depositos'));
    });

    test('el abono que no es efectivo se marca como fuera de la gaveta', () {
      final text = build(payments: creditPayments);
      expect(text, contains('Otras formas'));
      expect(text, contains('no entra a la gaveta'));
    });

    test('sin abonos el cierre sale exactamente como antes', () {
      expect(build(payments: null), isNot(contains('ABONOS A CREDITO')));
      expect(
        build(payments: {'total': 0.0, 'count': 0, 'payments': const []}),
        isNot(contains('ABONOS A CREDITO')),
      );
    });

    test('el bloque NO altera el cuadre', () {
      // Mismo input y mismo result: los esperados y la diferencia tienen que
      // imprimirse idénticos con y sin abonos. El bloque es informativo.
      final sin = build(payments: null);
      final con = build(payments: creditPayments);

      for (final linea in sin.split('\n')) {
        final t = linea.trim();
        if (t.isEmpty) continue;
        if (t.startsWith('Impreso:')) continue;
        expect(con, contains(t), reason: 'desapareció del cierre: "$t"');
      }
    });

    test('a 58mm ningún renglón del bloque pasa de 32 columnas', () {
      final text = build(payments: creditPayments, paperWidth: 58);
      for (final line in text.split('\n')) {
        expect(line.length, lessThanOrEqualTo(32), reason: 'renglón: "$line"');
      }
      expect(text, contains('ya en depositos'));
    });
  });
}
