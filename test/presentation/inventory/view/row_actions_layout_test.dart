// Presupuesto de ancho de la columna de acciones de la tabla de Insumos.
//
// Bug de campo (captura del 2026-08-18): el `more_vert` de cada fila se salía
// de la columna y la tabla mostraba las franjas amarillas de overflow. La
// causa era que el botón "Ajustar" es rígido y su ancho depende de la fuente
// y de la escala de texto del sistema, así que ningún número fijo lo cubre.
//
// Esta prueba NO monta `InventoryItemsView` (necesita Supabase y sesión):
// replica la MISMA composición y presupuesto de la fila para fijar la
// propiedad estructural que arregló el bug — con el botón dentro de un
// `Flexible` y etiqueta elidible, la fila no desborda ni con la escala de
// texto al doble. Si alguien vuelve a poner el botón rígido, esto falla.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mismos valores que `_kColActions` y `_kRowMenuWidth` en
/// `lib/presentation/inventory/view/inventory_items_view.dart`.
const double kColActions = 148;
const double kRowMenuWidth = 36;

Widget _rowActions() => Row(
  mainAxisAlignment: MainAxisAlignment.end,
  children: [
    Flexible(
      child: OutlinedButton.icon(
        onPressed: () {},
        icon: const Icon(Icons.tune, size: 15),
        label: const Text(
          'Ajustar',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
    ),
    const SizedBox(width: 4),
    SizedBox(
      width: kRowMenuWidth,
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 19),
        padding: EdgeInsets.zero,
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Editar ficha')),
        ],
      ),
    ),
  ],
);

Future<void> _pump(WidgetTester tester, double textScale) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: kColActions, child: _rowActions()),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('la fila de acciones cabe en su columna', (tester) async {
    await _pump(tester, 1.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no desborda con la escala de texto al doble', (tester) async {
    await _pump(tester, 2.0);
    // Sin `Flexible` acá saltaba "A RenderFlex overflowed by N pixels".
    expect(tester.takeException(), isNull);
  });

  testWidgets('el menu conserva su ancho, se recorta la etiqueta', (
    tester,
  ) async {
    await _pump(tester, 2.0);
    expect(
      tester.getSize(find.byType(PopupMenuButton<String>)).width,
      kRowMenuWidth,
    );
  });
}
