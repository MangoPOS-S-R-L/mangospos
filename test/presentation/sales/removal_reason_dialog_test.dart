// El diálogo que pregunta POR QUÉ se quita el producto y QUÉ pasa con el
// inventario. Lo importante: no deja quitar sin motivo, el motivo trae el
// destino correcto, y el cajero lo puede cambiar.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/order_item_removal_reason.dart';
import 'package:mangopos/presentation/sales/view/widgets/removal_reason_dialog.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// Sin negocio activo el diálogo no consulta el catálogo del servidor y usa
/// los motivos de fábrica, que es justo lo que se quiere probar.
class _FakeSession extends SessionController {
  @override
  SessionState build() => const SessionState();
}

/// Pantalla de tablet: el diálogo completo no cabe en los 800x600 por
/// defecto y los controles de abajo quedan fuera del área táctil.
void _tabletScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<OrderItemRemovalDecision?> _open(
  WidgetTester tester, {
  bool alreadySent = true,
}) async {
  OrderItemRemovalDecision? result;
  _tabletScreen(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sessionProvider.overrideWith(_FakeSession.new)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showRemovalReasonDialog(
                  context,
                  productName: 'Old Parr 18 Años 750Ml',
                  quantity: 1,
                  alreadySent: alreadySent,
                );
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('sin motivo no se puede quitar el producto', (tester) async {
    await _open(tester);
    expect(find.text('Quitar producto de la cuenta'), findsOneWidget);
    expect(find.text('1 × Old Parr 18 Años 750Ml'), findsOneWidget);
    expect(find.text('La comanda ya salió a cocina.'), findsOneWidget);

    final boton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'QUITAR PRODUCTO'),
    );
    expect(boton.onPressed, isNull);
  });

  testWidgets('el motivo trae el destino del inventario', (tester) async {
    await _open(tester);
    // "Ya preparado, se botó" está marcado como merma en el catálogo.
    await tester.tap(find.text('Ya preparado, se botó'));
    await tester.pump();
    expect(
      find.text('Se descuenta del inventario: el producto salió y no vuelve.'),
      findsOneWidget,
    );

    // "Error de digitación" devuelve.
    await tester.tap(find.text('Error de digitación'));
    await tester.pump();
    expect(
      find.text('Vuelve al inventario: no llegó a prepararse.'),
      findsOneWidget,
    );
  });

  testWidgets('devuelve el motivo, la nota y la merma elegida', (tester) async {
    OrderItemRemovalDecision? decision;
    _tabletScreen(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWith(_FakeSession.new)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  decision = await showRemovalReasonDialog(
                    context,
                    productName: 'Old Parr 18',
                    quantity: 2,
                  );
                },
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Error de digitación'));
    await tester.pump();
    // El cajero corrige: esta vez el trago sí se había servido.
    await tester.tap(find.text('Merma'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'El bar ya la abrió');
    await tester.tap(find.text('QUITAR PRODUCTO'));
    await tester.pumpAndSettle();

    expect(decision, isNotNull);
    expect(decision!.reason.code, 'typo');
    expect(decision!.isWaste, isTrue);
    expect(decision!.note, 'El bar ya la abrió');
    expect(decision!.text, 'Error de digitación: El bar ya la abrió');
    expect(decision!.inventoryLabel, 'Merma: NO vuelve al inventario');
  });

  testWidgets('cancelar no devuelve nada', (tester) async {
    await _open(tester);
    await tester.tap(find.text('Ya preparado, se botó'));
    await tester.pump();
    await tester.tap(find.text('CANCELAR'));
    await tester.pumpAndSettle();
    expect(find.text('Quitar producto de la cuenta'), findsNothing);
  });
}
