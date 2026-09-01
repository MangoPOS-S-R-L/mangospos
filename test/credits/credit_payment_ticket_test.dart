import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/credits/state/credit_payment_receipt.dart';
import 'package:mangopos/services/printing/credit_payment_ticket.dart';

CreditPaymentReceipt _receipt({
  String code = 'AB-00007',
  double amount = 1500,
  double balanceAfter = 3500,
  double originalAmount = 5000,
  String methodCode = 'cash',
  String methodName = 'Efectivo',
  String? customerName = 'Colmado La Esquina',
  String? reference,
  String creditStatus = 'partial',
}) {
  return CreditPaymentReceipt(
    code: code,
    paymentId: 'pay-1',
    creditId: 'credit-1',
    amount: amount,
    methodCode: methodCode,
    methodName: methodName,
    reference: reference,
    customerName: customerName,
    balanceAfter: balanceAfter,
    originalAmount: originalAmount,
    creditStatus: creditStatus,
    createdAt: DateTime(2026, 9, 2, 20, 30),
  );
}

String _print(CreditPaymentReceipt receipt, {int paperWidth = 80}) {
  return CreditPaymentTicket.build(
    receipt: receipt,
    businessName: 'Penda Express',
    paperWidth: paperWidth,
  ).rawText!;
}

void main() {
  group('CreditPaymentTicket', () {
    test('dice ABONO A CREDITO, no factura', () {
      final text = _print(_receipt());
      expect(text, contains('ABONO A CREDITO'));
      expect(text, contains('RECIBO DE PAGO'));
      // Un abono no vende nada: el ITBIS ya se declaró el día que se fió.
      expect(text.toUpperCase(), isNot(contains('ITBIS')));
      expect(text.toUpperCase(), isNot(contains('NCF')));
    });

    test('imprime el número del recibo', () {
      expect(_print(_receipt()), contains('AB-00007'));
    });

    test('las tres cifras: deuda, abono y saldo que queda', () {
      final text = _print(_receipt(
        amount: 1500,
        balanceAfter: 3500,
        originalAmount: 5000,
      ));
      expect(text, contains('Deuda original'));
      // Saldo anterior = lo que queda + lo que acaba de abonar.
      expect(text, contains('Saldo anterior'));
      expect(text, contains('5,000.00'));
      expect(text, contains('1,500.00'));
      expect(text, contains('3,500.00'));
      expect(text, contains('SALDO PENDIENTE'));
    });

    test('un abono que salda la cuenta lo grita', () {
      final text = _print(_receipt(
        amount: 5000,
        balanceAfter: 0,
        creditStatus: 'paid',
      ));
      expect(text, contains('CUENTA SALDADA'));
    });

    test('un abono parcial NO dice saldada', () {
      expect(_print(_receipt()), isNot(contains('CUENTA SALDADA')));
    });

    test('sale igual pagando con tarjeta, con su referencia', () {
      final text = _print(_receipt(
        methodCode: 'card',
        methodName: 'Tarjeta',
        reference: 'AUTH 998877',
      ));
      expect(text, contains('Tarjeta'));
      expect(text, contains('AUTH 998877'));
      expect(text, contains('ABONO'));
    });

    test('la reimpresión va marcada', () {
      final text = CreditPaymentTicket.build(
        receipt: _receipt(),
        businessName: 'Penda Express',
        isReprint: true,
      ).rawText!;
      expect(text, contains('REIMPRESION'));
    });

    test('a 58mm ningún renglón pasa de 32 columnas', () {
      final text = _print(
        _receipt(customerName: 'Distribuidora Hermanos Rodríguez y Asociados'),
        paperWidth: 58,
      );
      for (final line in text.split('\n')) {
        expect(line.length, lessThanOrEqualTo(32), reason: 'renglón: "$line"');
      }
    });

    test('sin nombre de cliente no deja un renglón vacío', () {
      final text = _print(_receipt(customerName: null));
      expect(text, isNot(contains('Cliente:')));
    });
  });

  group('CreditPaymentReceipt.fromRpc', () {
    test('lee el jsonb de fn_register_credit_abono_v2', () {
      final receipt = CreditPaymentReceipt.fromRpc({
        'id': 'pay-9',
        'credit_id': 'credit-9',
        'code': 'AB-00012',
        'amount': '750.50',
        'method_code': 'transfer',
        'method_name': 'Transferencia',
        'reference': '  ',
        'customer_name': 'Bar Mediotiempo',
        'balance_after': 0,
        'original_amount': 750.5,
        'credit_status': 'paid',
        'created_at': '2026-09-02T20:30:00Z',
      });

      expect(receipt.code, 'AB-00012');
      expect(receipt.amount, 750.5);
      // Una referencia en blanco es lo mismo que no tenerla: si no se
      // normaliza, el ticket imprime "Referencia:" y nada al lado.
      expect(receipt.reference, isNull);
      expect(receipt.isSettled, isTrue);
      expect(receipt.isCash, isFalse);
    });

    test('un abono sin número no rompe: queda vacío', () {
      final receipt = CreditPaymentReceipt.fromRpc({
        'id': 'pay-1',
        'amount': 100,
      });
      expect(receipt.code, isEmpty);
      expect(receipt.methodCode, 'cash');
      expect(receipt.methodName, 'Efectivo');
    });
  });

  group('CreditPaymentReceipt.fromHistoryRow', () {
    test('toma el método del embed y el saldo del crédito', () {
      final receipt = CreditPaymentReceipt.fromHistoryRow(
        {
          'id': 'pay-3',
          'credit_id': 'credit-3',
          'code': 'AB-00003',
          'amount': 200,
          'reference': 'CHQ-55',
          'created_at': '2026-08-30T15:00:00Z',
          'payment_methods': {'name': 'Tarjeta', 'code': 'card'},
        },
        credit: {
          'balance': 800,
          'original_amount': 1000,
          'status': 'partial',
          'customers': {'name': 'Penda Express'},
        },
      );

      expect(receipt.code, 'AB-00003');
      expect(receipt.methodName, 'Tarjeta');
      expect(receipt.customerName, 'Penda Express');
      // El historial no guarda el saldo posterior de cada abono: se reimprime
      // con el VIGENTE del crédito.
      expect(receipt.balanceAfter, 800);
      expect(receipt.isSettled, isFalse);
    });
  });
}
