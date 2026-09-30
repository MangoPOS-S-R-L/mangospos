import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/view/widgets/product_detail_modal.dart';

const _marker = '[LOYALTY:0f8b7c1e-2d3a-4b5c-8d9e-0a1b2c3d4e5f:1]';

/// Espresso de 100 con el premio de la tarjeta de sellos: 1 de 1 gratis.
OrderItem _rewardItem() => OrderItem(
  id: 'item-1',
  orderId: 'order-1',
  productId: 'menu-item-1',
  productName: 'Espresso',
  quantity: 1,
  unitPrice: 100,
  subtotal: 100,
  discounts: 100,
  tax: 0,
  total: 0,
  isTakeout: false,
  status: 'pending',
  notes: 'poco hielo\n$_marker',
  createdAt: DateTime(2026, 9, 30),
);

void main() {
  testWidgets(
    'línea con premio: subir la cantidad NO regala la segunda unidad y el '
    'marcador se conserva',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      OrderItem? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProductDetailModal(
              item: _rewardItem(),
              onSave: (item) async => saved = item,
              onDelete: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // El marcador no aparece en el campo de notas; sí el aviso del premio.
      final notesField = tester.widget<TextField>(
        find.byWidgetPredicate(
          (w) => w is TextField && w.controller?.text == 'poco hielo',
        ),
      );
      expect(notesField.controller!.text, 'poco hielo');
      expect(find.textContaining('Premio de fidelidad'), findsOneWidget);

      // Ni cortesía ni descuento manual se editan sobre el premio.
      final courtesySwitch = tester.widget<Switch>(
        find.descendant(
          of: find
              .ancestor(
                of: find.text('¿Deseas aplicar una cortesía?'),
                matching: find.byType(Row),
              )
              .first,
          matching: find.byType(Switch),
        ),
      );
      expect(courtesySwitch.onChanged, isNull);
      expect(find.textContaining('Cortesía total'), findsNothing);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.text('2'), findsOneWidget);

      await tester.tap(find.text('Guardar cambios').first);
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.quantity, 2);
      // Sigue siendo UNA unidad gratis (100), no las dos (200).
      expect(saved!.discounts, 100);
      expect(saved!.notes, contains('poco hielo'));
      expect(saved!.notes, contains(_marker));
    },
  );
}
