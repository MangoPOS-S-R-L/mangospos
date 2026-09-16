import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/inventory/item_presentations.dart';
import 'package:mangopos/presentation/inventory/view/widgets/item_presentations_editor.dart';

const _latasYCaja = [
  PresentationDraft(unit: 'Lata', containsQty: 355),
  PresentationDraft(unit: 'Caja', containsQty: 24, containsUnit: 'Lata', isPurchaseDefault: true),
];

Future<List<List<PresentationDraft>>> _pump(
  WidgetTester tester,
  List<PresentationDraft> initial,
) async {
  final emitted = <List<PresentationDraft>>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 580,
            child: ItemPresentationsEditor(
              baseUnit: 'ml',
              initial: initial,
              onChanged: emitted.add,
            ),
          ),
        ),
      ),
    ),
  );
  return emitted;
}

void main() {
  testWidgets('muestra la etiqueta encadenada y la estrella de la de compra', (tester) async {
    await _pump(tester, _latasYCaja);
    expect(find.text('1 Lata · 355 mL'), findsOneWidget);
    expect(find.text('1 Caja · 24 Lata · 8.52 L'), findsOneWidget);
    expect(find.byIcon(Icons.star), findsOneWidget);
  });

  testWidgets('la de compra es una sola: marcar la lata desmarca la caja', (tester) async {
    final emitted = await _pump(tester, _latasYCaja);
    await tester.tap(find.byIcon(Icons.star_border));
    await tester.pump();
    final last = emitted.last;
    expect(last.firstWhere((d) => d.unit == 'Lata').isPurchaseDefault, isTrue);
    expect(last.firstWhere((d) => d.unit == 'Caja').isPurchaseDefault, isFalse);
  });

  testWidgets('cambiar la lata recalcula la caja; quitar la lata deja el error a la vista', (tester) async {
    final emitted = await _pump(tester, _latasYCaja);
    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '355'),
      '330',
    );
    await tester.pump();
    expect(find.text('1 Caja · 24 Lata · 7.92 L'), findsOneWidget);

    await tester.tap(find.byTooltip('Quitar').first);
    await tester.pump();
    await tester.pump();
    expect(emitted.last.length, 1);
    expect(find.text('«Caja» contiene «Lata», que no está en la lista.'), findsOneWidget);
  });

  testWidgets('agregar llega hasta 5 y ahí se apaga', (tester) async {
    await _pump(tester, [
      for (var i = 0; i < 4; i++) PresentationDraft(unit: 'P$i', containsQty: 1),
    ]);
    await tester.tap(find.text('Agregar'));
    await tester.pump();
    final button = tester.widget<TextButton>(
      find.ancestor(of: find.text('Agregar'), matching: find.byWidgetPredicate((w) => w is TextButton)),
    );
    expect(button.onPressed, isNull);
    expect(find.byTooltip('Quitar'), findsNWidgets(5));
  });
}
