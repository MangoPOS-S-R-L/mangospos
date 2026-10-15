// Productos: cada filtro dice su nombre (pedido del dueño, 13-oct). En
// pantallas de menos de 1366 px las tres cajas decían «Todas / Todos /
// Todas» y no se sabía cuál era cuál.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/products/widgets/product_filter_dropdown.dart';

void main() {
  const categories = [
    {'id': 'c1', 'name': 'Bebidas'},
    {'id': 'c2', 'name': 'Postres'},
  ];

  Future<List<String?>> pump(
    WidgetTester tester, {
    required bool compact,
    String? value,
  }) async {
    final changes = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              if (compact)
                Expanded(
                  child: ProductFilterDropdown(
                    name: 'Categoría',
                    allLabel: 'Todas las categorías',
                    items: categories,
                    value: value,
                    onChanged: changes.add,
                    compact: true,
                  ),
                )
              else
                ProductFilterDropdown(
                  name: 'Categoría',
                  allLabel: 'Todas las categorías',
                  items: categories,
                  value: value,
                  onChanged: changes.add,
                  compact: false,
                ),
            ],
          ),
        ),
      ),
    );
    return changes;
  }

  for (final compact in [true, false]) {
    final mode = compact ? 'pantalla chica' : 'escritorio';

    testWidgets('$mode: sin filtro muestra el nombre del filtro, no «Todas»', (
      tester,
    ) async {
      await pump(tester, compact: compact);
      expect(find.text('Categoría'), findsOneWidget);
      expect(find.textContaining('Todas'), findsNothing);
      expect(find.text('CATEGORÍA'), findsNothing);
    });
  }

  testWidgets('pantalla chica con filtro: el valor y el nombre encima', (
    tester,
  ) async {
    await pump(tester, compact: true, value: 'c1');
    expect(find.text('Bebidas'), findsOneWidget);
    expect(find.text('CATEGORÍA'), findsOneWidget);
  });

  testWidgets('escritorio con filtro: «Categoría: Bebidas»', (tester) async {
    await pump(tester, compact: false, value: 'c1');
    expect(find.text('Categoría: Bebidas'), findsOneWidget);
  });

  testWidgets('el menú ofrece quitar el filtro con su nombre y lo quita', (
    tester,
  ) async {
    final changes = await pump(tester, compact: true, value: 'c2');
    await tester.tap(find.byType(ProductFilterDropdown));
    await tester.pumpAndSettle();

    expect(find.text('Todas las categorías'), findsOneWidget);
    expect(find.textContaining('--'), findsNothing);

    await tester.tap(find.text('Todas las categorías'));
    await tester.pumpAndSettle();
    expect(changes, [null]);
  });
}
