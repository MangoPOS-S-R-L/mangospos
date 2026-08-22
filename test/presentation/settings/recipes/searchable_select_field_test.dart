// Buscador de los selectores del formulario de recetas.
//
// Pedido de campo (2026-08-22): en "Nueva receta" tanto "Producto" como
// "Insumo" eran `DropdownButtonFormField`, es decir listas cerradas donde hay
// que bajar a mano entre cientos de productos/insumos. Se reemplazaron por
// `SearchableSelectField`, que se escribe para filtrar.
//
// Estas pruebas fijan las cuatro propiedades que hacen que el campo se pueda
// usar como reemplazo de un desplegable: muestra el valor elegido, al tocarlo
// despliega TODO el catalogo, escribir filtra (tambien por SKU) y salir sin
// elegir no deja el campo con basura escrita.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mangopos/presentation/settings/more%20settings/menus/recipes/view/widgets/searchable_select_field.dart';

class _Item {
  final String id;
  final String name;
  final String sku;
  const _Item(this.id, this.name, this.sku);
}

const _items = <_Item>[
  _Item('1', 'Coca Cola 600ml', 'BEB-001'),
  _Item('2', 'Ron Brugal', 'LIC-777'),
  _Item('3', 'Zumo para soda', 'BEB-050'),
];

/// Monta el campo con el estado que normalmente vive en el formulario.
Future<List<_Item>> _pumpField(
  WidgetTester tester, {
  _Item? initial,
}) async {
  final selections = <_Item>[];
  _Item? selected = initial;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 400,
            child: SearchableSelectField<_Item>(
              labelText: 'Insumo',
              items: _items,
              selected: selected,
              labelOf: (item) => item.name,
              subtitleOf: (item) => item.sku,
              keywordsOf: (item) => [item.sku],
              onSelected: (item) {
                selections.add(item);
                setState(() => selected = item);
              },
            ),
          ),
        ),
      ),
    ),
  );
  return selections;
}

TextEditingController _fieldController(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!;

/// Las opciones se dibujan en un overlay: se cuentan los `ListTile`.
Finder _option(String name) => find.widgetWithText(ListTile, name);

void main() {
  testWidgets('muestra el valor ya seleccionado', (tester) async {
    await _pumpField(tester, initial: _items[2]);
    expect(_fieldController(tester).text, 'Zumo para soda');
  });

  testWidgets('al tocarlo despliega el catalogo completo', (tester) async {
    await _pumpField(tester, initial: _items[2]);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(find.byType(ListTile), findsNWidgets(_items.length));
    // El texto se vacia para no filtrar por el valor que ya estaba.
    expect(_fieldController(tester).text, isEmpty);
  });

  testWidgets('escribir filtra por nombre y por SKU', (tester) async {
    await _pumpField(tester);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'brug');
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    expect(_option('Ron Brugal'), findsOneWidget);

    // El SKU tambien busca: en insumos es lo que trae la pistola.
    await tester.enterText(find.byType(TextField), 'BEB-050');
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    expect(_option('Zumo para soda'), findsOneWidget);
  });

  testWidgets('elegir una opcion la reporta y la deja en el campo', (
    tester,
  ) async {
    final selections = await _pumpField(tester);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'coca');
    await tester.pumpAndSettle();
    await tester.tap(_option('Coca Cola 600ml'));
    await tester.pumpAndSettle();

    expect(selections.map((i) => i.id), ['1']);
    expect(_fieldController(tester).text, 'Coca Cola 600ml');
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('salir sin elegir restaura el valor anterior', (tester) async {
    await _pumpField(tester, initial: _items[1]);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'xyz');
    await tester.pumpAndSettle();

    primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(_fieldController(tester).text, 'Ron Brugal');
  });
}
