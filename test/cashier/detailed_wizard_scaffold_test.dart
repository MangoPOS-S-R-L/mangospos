import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/cashier/detailed_wizard/cash_close_detailed_wizard.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';

void main() {
  const testInput = CashCloseInput(
    expectedCash: 0,
    expectedCard: 0,
    expectedTransfer: 0,
    totalSales: 0,
    transactionCount: 0,
    cashierName: 'Maria',
    businessName: 'Mango',
    startAmount: 5000,
  );

  Future<void> pumpWizard(
    WidgetTester tester, {
    Size size = const Size(1024, 768),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: CashCloseDetailedWizard(
            cashRegisterSessionId: 'session-test-1',
            input: testInput,
            cashierName: 'Maria',
            cashRegisterLabel: 'Caja 1',
            openedAt: DateTime(2026, 5, 10, 8),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renderiza header, stepper, paso 1 y footer', (tester) async {
    await pumpWizard(tester);

    expect(find.text('Cierre de caja'), findsOneWidget);
    expect(find.text('A ciegas'), findsOneWidget);
    expect(find.text('Caja 1 · Maria · 10/05/2026'), findsOneWidget);

    expect(find.text('1 · Efectivo'), findsOneWidget);
    expect(find.text('2 · Tarjeta y transferencia'), findsOneWidget);
    expect(find.text('3 · Confirmar'), findsOneWidget);

    expect(find.text('Cuenta los billetes y monedas que tienes en gaveta. Resta el fondo inicial al final.'), findsOneWidget);

    expect(find.text('Cancelar'), findsOneWidget);
    expect(find.text('Continuar'), findsOneWidget);
  });

  testWidgets(
    'el botón primario avanza por los 3 pasos cambiando label correctamente',
    (tester) async {
      await pumpWizard(tester);

      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();

      expect(find.text('Pagos electrónicos'), findsOneWidget);
      expect(find.text('Atrás'), findsOneWidget);
      expect(find.text('Revisar y confirmar'), findsOneWidget);

      await tester.tap(find.text('Revisar y confirmar'));
      await tester.pumpAndSettle();

      expect(find.text('Revisar y firmar'), findsOneWidget);
      expect(find.text('Firmar y cerrar caja'), findsOneWidget);
    },
  );

  testWidgets('el botón secundario regresa al paso anterior', (tester) async {
    await pumpWizard(tester);

    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atrás'));
    await tester.pumpAndSettle();

    expect(find.text('Cuenta los billetes y monedas que tienes en gaveta. Resta el fondo inicial al final.'), findsOneWidget);
    expect(find.text('Cancelar'), findsOneWidget);
  });

  testWidgets(
    'BILLETE y PEQUEÑAS van lado a lado en una sola fila',
    (tester) async {
      await pumpWizard(tester, size: const Size(720, 800));

      final billete = tester.getCenter(find.text('BILLETE'));
      final pequenas = tester.getCenter(find.text('PEQUEÑAS'));
      // Misma fila (Y aprox igual), distintas columnas (PEQUEÑAS a la derecha).
      expect((billete.dy - pequenas.dy).abs(), lessThan(2.0));
      expect(pequenas.dx, greaterThan(billete.dx));
    },
  );

  testWidgets(
    'Fondo inicial y Efectivo del turno van lado a lado',
    (tester) async {
      await pumpWizard(tester, size: const Size(720, 800));

      final opening = tester.getRect(find.text('Fondo inicial'));
      final shift = tester.getRect(find.text('Efectivo del turno'));
      // Side-by-side: misma fila (rectángulos verticales overlap) y
      // PEQUEÑAS a la derecha de BILLETE.
      expect(
        opening.bottom > shift.top && shift.bottom > opening.top,
        isTrue,
        reason: 'cards no overlapan verticalmente',
      );
      expect(shift.left, greaterThan(opening.right));
    },
  );

  testWidgets('a 600 px de ancho los 3 pasos renderizan sin overflow', (
    tester,
  ) async {
    final overflows = <String>[];
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      final msg = details.exception.toString();
      if (msg.contains('overflowed')) overflows.add(msg);
    };
    addTearDown(() => FlutterError.onError = original);

    await pumpWizard(tester, size: const Size(600, 800));
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revisar y confirmar'));
    await tester.pumpAndSettle();

    expect(overflows, isEmpty, reason: 'overflows en 360 px: $overflows');
  });
}
