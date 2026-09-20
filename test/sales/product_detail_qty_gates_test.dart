import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/view/widgets/product_detail_modal.dart';

/// Ítem ya enviado a cocina, como el que abre el mesero desde el ticket.
OrderItem _sentItem() => OrderItem(
  id: 'item-1',
  orderId: 'order-1',
  productId: 'menu-item-1',
  productName: 'Presidente Grande',
  quantity: 2,
  unitPrice: 250,
  subtotal: 500,
  discounts: 0,
  tax: 0,
  total: 500,
  isTakeout: false,
  status: 'pending',
  createdAt: DateTime(2026, 9, 19),
);

Future<void> _pumpModal(
  WidgetTester tester, {
  String? addMoreBlockedReason,
  double? reduceFloor,
  VoidCallback? onReprint,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProductDetailModal(
          item: _sentItem(),
          addMoreBlockedReason: addMoreBlockedReason,
          reduceFloor: reduceFloor,
          reduceBlockedReason: 'Solo un supervisor puede quitarlo.',
          onReprint: onReprint,
          onSave: (_) async {},
          onDelete: (_) async {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// El "+" del contador de cantidad.
IconButton _addButton(WidgetTester tester) => tester.widget<IconButton>(
  find.ancestor(
    of: find.byIcon(Icons.add),
    matching: find.byType(IconButton),
  ),
);

/// El "−" del contador de cantidad.
IconButton _removeButton(WidgetTester tester) => tester.widget<IconButton>(
  find.ancestor(
    of: find.byIcon(Icons.remove),
    matching: find.byType(IconButton),
  ),
);

void main() {
  testWidgets('sin bloqueo el + suma unidades', (tester) async {
    await _pumpModal(tester);

    expect(_addButton(tester).onPressed, isNotNull);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(find.text('3'), findsOneWidget);
  });

  testWidgets(
    'producto desactivado: el + queda apagado',
    (tester) async {
      await _pumpModal(
        tester,
        addMoreBlockedReason:
            'Presidente Grande ya no está activo en el menú. No se le '
            'pueden agregar más unidades hasta que lo reactiven.',
      );

      expect(_addButton(tester).onPressed, isNull);

      // Aunque se toque, la cantidad no se mueve.
      await tester.tap(find.byIcon(Icons.add), warnIfMissed: false);
      await tester.pump();
      expect(find.text('2'), findsOneWidget);

      // Bajar la cantidad NO se ve afectado por el bloqueo del "+".
      expect(_removeButton(tester).onPressed, isNotNull);
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
    },
  );

  testWidgets(
    'sin permiso para eliminar: el − no baja de lo ya enviado',
    (tester) async {
      // Las 2 unidades del ítem ya salieron a cocina.
      await _pumpModal(tester, reduceFloor: 2);

      expect(_removeButton(tester).onPressed, isNull);
      await tester.tap(find.byIcon(Icons.remove), warnIfMissed: false);
      await tester.pump();
      expect(find.text('2'), findsOneWidget);

      // El "+" no se toca: sube normal.
      expect(_addButton(tester).onPressed, isNotNull);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.text('3'), findsOneWidget);
    },
  );

  testWidgets(
    'lo que sumó y no ha enviado sí lo puede devolver, hasta el piso',
    (tester) async {
      // Caso real: 2 enviadas, toca "+" dos veces y se arrepiente.
      await _pumpModal(tester, reduceFloor: 2);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.text('4'), findsOneWidget);

      // Puede devolver las 2 que todavía no salieron.
      expect(_removeButton(tester).onPressed, isNotNull);
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
      expect(find.text('2'), findsOneWidget);

      // Y ahí se apaga: las 2 enviadas no las toca.
      expect(_removeButton(tester).onPressed, isNull);
    },
  );

  testWidgets('sin piso el − baja hasta 1 y no más', (tester) async {
    await _pumpModal(tester);

    await tester.tap(find.byIcon(Icons.remove));
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    expect(_removeButton(tester).onPressed, isNull);
  });

  testWidgets('los bloqueos apagan los botones y no imprimen nota', (
    tester,
  ) async {
    await _pumpModal(
      tester,
      addMoreBlockedReason: 'Producto inactivo.',
      reduceFloor: 2,
    );

    expect(_addButton(tester).onPressed, isNull);
    expect(_removeButton(tester).onPressed, isNull);
    // Los motivos quedan de tooltip, no ocupan espacio en el modal.
    expect(find.text('Producto inactivo.'), findsNothing);
    expect(find.text('Solo un supervisor puede quitarlo.'), findsNothing);
  });

  testWidgets('sin onReprint no se dibuja "Reimprimir comanda"', (
    tester,
  ) async {
    await _pumpModal(tester);
    expect(find.text('Reimprimir comanda'), findsNothing);

    await _pumpModal(tester, onReprint: () {});
    expect(find.text('Reimprimir comanda'), findsOneWidget);
  });
}
