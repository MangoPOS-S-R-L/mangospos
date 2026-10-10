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
  Future<bool> Function()? onAuthorizeReduce,
  Future<void> Function(OrderItem item)? onSave,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProductDetailModal(
          item: _sentItem(),
          addMoreBlockedReason: addMoreBlockedReason,
          reduceFloor: reduceFloor,
          reduceBlockedReason: 'Solo un supervisor puede quitarlo.',
          onAuthorizeReduce: onAuthorizeReduce,
          onReprint: onReprint,
          onSave: onSave ?? (_) async {},
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

  testWidgets(
    'cajero en el piso: el − pide PIN de supervisor y, con PIN, baja',
    (tester) async {
      // Caso real: el cajero quería quitar 1 de las 2 ya enviadas y su única
      // salida era «Eliminar», que borraba las dos.
      var pinRequests = 0;
      await _pumpModal(
        tester,
        reduceFloor: 2,
        onAuthorizeReduce: () async {
          pinRequests++;
          return true;
        },
      );

      expect(_removeButton(tester).onPressed, isNotNull);
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pumpAndSettle();

      expect(pinRequests, 1);
      expect(find.text('1'), findsOneWidget);
    },
  );

  testWidgets('PIN rechazado: la cantidad no se mueve', (tester) async {
    await _pumpModal(
      tester,
      reduceFloor: 2,
      onAuthorizeReduce: () async => false,
    );

    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('con el PIN ya puesto no lo vuelve a pedir', (tester) async {
    var pinRequests = 0;
    await _pumpModal(
      tester,
      reduceFloor: 2,
      onAuthorizeReduce: () async {
        pinRequests++;
        return true;
      },
    );

    // Sube a 3, baja a 1: el PIN se pide una sola vez, al cruzar el piso.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    expect(pinRequests, 0, reason: 'la que sumó y no envió la devuelve sola');
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    expect(pinRequests, 1);
    expect(find.text('1'), findsOneWidget);
    // En 1 se apaga: de ahí en adelante es «Eliminar».
    expect(_removeButton(tester).onPressed, isNull);
  });

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

  group('cantidad escrita', () {
    Finder qtyField() => find.byKey(const ValueKey('product-detail-qty'));

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(qtyField(), text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    Future<void> tapSave(WidgetTester tester) async {
      await tester.ensureVisible(find.text('Guardar cambios'));
      await tester.tap(find.text('Guardar cambios'));
      await tester.pumpAndSettle();
    }

    testWidgets('se escribe y se guarda esa cantidad', (tester) async {
      OrderItem? saved;
      await _pumpModal(tester, onSave: (item) async => saved = item);

      await type(tester, '12');
      expect(find.text('12'), findsOneWidget);

      // Los botones siguen desde lo escrito.
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.text('13'), findsOneWidget);

      await tapSave(tester);
      expect(saved?.quantity, 13);
    });

    testWidgets('«Guardar» aplica lo escrito aunque no le diera Enter', (
      tester,
    ) async {
      OrderItem? saved;
      await _pumpModal(tester, onSave: (item) async => saved = item);

      await tester.enterText(qtyField(), '4');
      await tapSave(tester);
      expect(saved?.quantity, 4);
    });

    testWidgets('vacío o 0 vuelve a la última cantidad', (tester) async {
      await _pumpModal(tester);

      await type(tester, '');
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Escribe una cantidad entre 1 y 999.'), findsOneWidget);

      await type(tester, '0');
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('producto inactivo: no se escribe más de lo que había', (
      tester,
    ) async {
      await _pumpModal(tester, addMoreBlockedReason: 'Producto inactivo.');

      await type(tester, '5');
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Producto inactivo.'), findsOneWidget);

      // Bajar sí se puede.
      await type(tester, '1');
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('sin PIN no se escribe por debajo de lo enviado', (
      tester,
    ) async {
      await _pumpModal(tester, reduceFloor: 2);

      await type(tester, '1');
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Solo un supervisor puede quitarlo.'), findsOneWidget);
    });

    testWidgets('bajo lo enviado pide PIN una vez; rechazado, vuelve', (
      tester,
    ) async {
      var pinRequests = 0;
      var allow = false;
      await _pumpModal(
        tester,
        reduceFloor: 2,
        onAuthorizeReduce: () async {
          pinRequests++;
          return allow;
        },
      );

      await type(tester, '1');
      expect(pinRequests, 1);
      expect(find.text('2'), findsOneWidget);

      allow = true;
      await type(tester, '1');
      expect(pinRequests, 2);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('perder el foco y «Guardar» no piden el PIN dos veces', (
      tester,
    ) async {
      var pinRequests = 0;
      await _pumpModal(
        tester,
        reduceFloor: 2,
        onAuthorizeReduce: () async {
          pinRequests++;
          return false;
        },
      );

      await tester.enterText(qtyField(), '1');
      await tapSave(tester);
      expect(pinRequests, 1);
      expect(find.text('2'), findsOneWidget);
    });
  });
}
