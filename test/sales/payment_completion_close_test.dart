import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/sales/logic/payment_completion_gate.dart';
import 'package:mangopos/presentation/sales/widgets/payment_success_dialog.dart';

void main() {
  test('sale una sola vez aunque cierre y confirme en distinto orden', () {
    for (final closeFirst in [false, true]) {
      var exits = 0;
      final gate = PaymentCompletionGate(() => exits++);
      if (closeFirst) {
        gate.close();
        expect(exits, 0);
        gate.confirm();
      } else {
        gate.confirm();
        expect(exits, 0);
        gate.close();
      }
      gate.confirm();
      gate.close(hasPaymentResult: true);
      expect(exits, 1);
    }
  });

  test('cancelar antes de confirmar no sale de la mesa', () {
    var exits = 0;
    PaymentCompletionGate(() => exits++).close();
    expect(exits, 0);
  });

  testWidgets('Cerrar en imprimir copia resuelve el dialogo', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await showPaymentSuccessDialog(
                  context: context,
                  onReprint: () async {},
                );
                closed = true;
              },
              child: const Text('Mostrar pago'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Mostrar pago'));
    await tester.pumpAndSettle();
    expect(find.text('Imprimir copia'), findsOneWidget);
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(find.text('Imprimir copia'), findsNothing);
  });

  testWidgets('Cerrar funciona aunque una copia siga imprimiendo', (
    tester,
  ) async {
    final printCompleter = Completer<void>();
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await showPaymentSuccessDialog(
                  context: context,
                  onReprint: () => printCompleter.future,
                );
                closed = true;
              },
              child: const Text('Mostrar pago'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Mostrar pago'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Imprimir copia'));
    await tester.pump();
    expect(find.text('Imprimiendo copia...'), findsOneWidget);
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    printCompleter.complete();
    await tester.pump();
  });
}
