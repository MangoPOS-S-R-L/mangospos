import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/widgets/blind_cash_close_dialog.dart';
import 'package:mangopos/presentation/cashier/widgets/denomination_counter_row.dart';
import 'package:mangopos/presentation/cashier/widgets/numpad_widget.dart';

void main() {
  Future<void> pumpDialog(
    WidgetTester tester, {
    required CashCloseInput input,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: BlindCashCloseDialog(sessionId: 'session-test', input: input),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> increment100(WidgetTester tester, {int times = 1}) async {
    final row = find.ancestor(
      of: find.text('RD\$ 100').first,
      matching: find.byType(DenominationCounterRow),
    );
    final plus = find.descendant(
      of: row,
      matching: find.byIcon(Icons.add_circle_outline),
    );
    for (var i = 0; i < times; i++) {
      await tester.tap(plus);
      await tester.pump();
    }
  }

  Future<void> tapMainConfirm(WidgetTester tester) async {
    await tester.tap(find.text('Confirmar Conteo').first);
    await tester.pumpAndSettle();
  }

  Future<void> tapDialogConfirm(WidgetTester tester) async {
    final alert = find.byType(AlertDialog);
    expect(alert, findsOneWidget);
    await tester.tap(
      find.descendant(of: alert, matching: find.text('Confirmar Conteo')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('flujo conteo -> confirmacion -> resultado cuadrado', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const input = CashCloseInput(
      expectedCash: 100,
      expectedCard: 0,
      expectedTransfer: 0,
      totalSales: 100,
      transactionCount: 1,
    );

    await pumpDialog(tester, input: input);
    await increment100(tester, times: 1);
    await tapMainConfirm(tester);

    expect(find.textContaining('TOTAL REPORTADO: RD\$ 100'), findsOneWidget);
    await tapDialogConfirm(tester);

    expect(find.text('Caja cuadrada'), findsOneWidget);
  });

  testWidgets('muestra sobrante cuando difference > 0', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const input = CashCloseInput(
      expectedCash: 100,
      expectedCard: 0,
      expectedTransfer: 0,
      totalSales: 100,
      transactionCount: 1,
    );

    await pumpDialog(tester, input: input);
    await increment100(tester, times: 2);
    await tapMainConfirm(tester);
    await tapDialogConfirm(tester);

    expect(find.text('Sobrante detectado'), findsOneWidget);
  });

  testWidgets('muestra faltante cuando difference < 0', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const input = CashCloseInput(
      expectedCash: 100,
      expectedCard: 0,
      expectedTransfer: 0,
      totalSales: 100,
      transactionCount: 1,
    );

    await pumpDialog(tester, input: input);
    expect(find.byType(NumpadWidget), findsOneWidget);

    await tapMainConfirm(tester);
    await tapDialogConfirm(tester);

    expect(find.text('Faltante detectado'), findsOneWidget);
  });

  testWidgets('tras confirmar conteo no permite volver al conteo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const input = CashCloseInput(
      expectedCash: 100,
      expectedCard: 0,
      expectedTransfer: 0,
      totalSales: 100,
      transactionCount: 1,
    );

    await pumpDialog(tester, input: input);
    await increment100(tester, times: 1);
    await tapMainConfirm(tester);
    await tapDialogConfirm(tester);

    expect(find.text('Volver al conteo'), findsNothing);
    expect(find.text('Caja cuadrada'), findsOneWidget);
  });
}
