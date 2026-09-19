import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/models/table_deposit_coverage.dart';
import 'package:mangopos/presentation/sales/widgets/precheck/pre_check_dialog.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

Order _order(double total) => Order(
  id: 'order-1',
  sessionId: 'session-1',
  status: 'open',
  subtotal: total,
  discounts: 0,
  serviceFee: 0,
  tax: 0,
  total: total,
  createdAt: DateTime(2026, 9, 18, 22, 15),
);

OrderItem _item(double total) => OrderItem(
  id: 'item-1',
  orderId: 'order-1',
  productName: 'Botella',
  quantity: 1,
  unitPrice: total,
  subtotal: total,
  discounts: 0,
  tax: 0,
  total: total,
  isTakeout: false,
  status: 'pending',
  taxMode: 'exclusive',
  taxRate: 0,
  createdAt: DateTime(2026, 9, 18, 22, 15),
);

String _precheck(
  double total, {
  double? deposit,
  String template = 'standard',
}) {
  final ticket = PrintTicketService.generatePrecheck(
    order: _order(total),
    items: [_item(total)],
    tableName: 'MUEBLE04',
    businessName: 'Negocio',
    template: template,
    tableDepositAvailable: deposit,
  );
  return latin1.decode(ticket.escPosCommands, allowInvalid: true);
}

void main() {
  // Lo que pidió el negocio: "que en la precuenta salga el balance que tienen,
  // así solo deben pagar la diferencia".
  group('cálculo: cuánto cubre el abono y cuánto se paga', () {
    test('consumo 9,500 con 9,000 de abono: la diferencia es 500', () {
      final c = TableDepositCoverage.of(total: 9500, available: 9000)!;

      expect(c.available, 9000);
      expect(c.covered, 9000);
      expect(c.toPay, 500);
      expect(c.remaining, 0);
      expect(c.coversAll, isFalse);
    });

    test('consumo 1,000 con 10,000 de abono: no paga nada y quedan 9,000', () {
      final c = TableDepositCoverage.of(total: 1000, available: 10000)!;

      expect(c.toPay, 0);
      expect(c.remaining, 9000);
      expect(c.coversAll, isTrue);
    });

    test('abono exacto: paga 0 y la mesa queda en 0', () {
      final c = TableDepositCoverage.of(total: 9000, available: 9000)!;

      expect(c.toPay, 0);
      expect(c.remaining, 0);
      expect(c.coversAll, isTrue);
    });

    test('sin abono no hay bloque: la precuenta sale como siempre', () {
      expect(TableDepositCoverage.of(total: 1000, available: null), isNull);
      expect(TableDepositCoverage.of(total: 1000, available: 0), isNull);
    });

    test('los centavos no dejan una diferencia fantasma', () {
      // 0.1 + 0.2 en double no es 0.3; la diferencia tiene que salir limpia.
      final c = TableDepositCoverage.of(total: 1500.30, available: 1500.10)!;

      expect(c.toPay, 0.20);
    });
  });

  group('precuenta impresa', () {
    test('el abono no alcanza: dice cuánto tiene y la diferencia', () {
      final text = _precheck(9500, deposit: 9000);

      expect(text, contains('ABONO DISPONIBLE:'));
      expect(text, contains('9,000.00'));
      expect(text, contains('DIFERENCIA A PAGAR:'));
      expect(text, contains('500.00'));
      // Si hay diferencia, no se habla de saldo que queda: se agota.
      expect(text, isNot(contains('SALDO QUE QUEDA')));
    });

    test('el abono cubre todo: a pagar 0 y cuánto le queda a la mesa', () {
      final text = _precheck(1000, deposit: 10000);

      expect(text, contains('ABONO DISPONIBLE:'));
      expect(text, contains('10,000.00'));
      expect(text, contains('A PAGAR:'));
      expect(text, isNot(contains('DIFERENCIA A PAGAR')));
      expect(text, contains('SALDO QUE QUEDA:'));
      expect(text, contains('9,000.00'));
    });

    test('el TOTAL sigue siendo lo consumido: es lo que se factura', () {
      final text = _precheck(9500, deposit: 9000);

      expect(text, contains('TOTAL:'));
      expect(text, contains('9,500.00'));
    });

    test('mesa sin abono: la precuenta no cambia', () {
      final text = _precheck(1000);

      expect(text, isNot(contains('ABONO')));
      expect(text, isNot(contains('A PAGAR')));
    });

    test('plantilla moderna también lo imprime', () {
      final text = _precheck(9500, deposit: 9000, template: 'modern');

      expect(text, contains('Abono disponible'));
      expect(text, contains('Diferencia a pagar'));
      expect(text, contains('500.00'));
    });
  });

  group('precuenta en pantalla (sin impresora)', () {
    Future<void> pumpDialog(WidgetTester tester, Map<String, dynamic> data) =>
        tester.pumpWidget(
          MaterialApp(
            home: PreCheckDialog(
              data: data,
              onPrint: () {},
              onCancel: () {},
            ),
          ),
        );

    Map<String, dynamic> dataFor(double total, {double? deposit}) => {
      'restaurantName': 'Negocio',
      'tableName': 'MUEBLE04',
      'items': [
        {'quantity': 1, 'name': 'Botella', 'price': total},
      ],
      'subtotal': total,
      'tax': 0.0,
      'total': total,
      'tableDepositBalance': ?deposit,
    };

    testWidgets('muestra el abono y la diferencia', (tester) async {
      await pumpDialog(tester, dataFor(9500, deposit: 9000));
      await tester.pump();
      // Mismo desborde del encabezado que en pre_check_dialog_totals_test:
      // la fuente de prueba es más ancha que la real.
      tester.takeException();

      expect(find.text('Abono disponible'), findsOneWidget);
      expect(find.text('DIFERENCIA A PAGAR'), findsOneWidget);
      expect(find.text('RD\$ 500.00'), findsOneWidget);
    });

    testWidgets('abono que cubre todo: a pagar 0 y saldo que queda', (
      tester,
    ) async {
      await pumpDialog(tester, dataFor(1000, deposit: 10000));
      await tester.pump();
      tester.takeException();

      expect(find.text('A PAGAR'), findsOneWidget);
      // El 0.00 se busca DENTRO de la fila "A PAGAR": el diálogo también
      // pinta el impuesto en 0.00 más arriba.
      final aPagarRow = find
          .ancestor(of: find.text('A PAGAR'), matching: find.byType(Row))
          .first;
      expect(
        find.descendant(of: aPagarRow, matching: find.text('RD\$ 0.00')),
        findsOneWidget,
      );
      expect(find.text('Saldo que queda'), findsOneWidget);
      expect(find.text('RD\$ 9,000.00'), findsOneWidget);
    });

    testWidgets('sin abono el diálogo se ve como siempre', (tester) async {
      await pumpDialog(tester, dataFor(1000));
      await tester.pump();
      tester.takeException();

      expect(find.text('Abono disponible'), findsNothing);
      expect(find.textContaining('A PAGAR'), findsNothing);
    });
  });
}
