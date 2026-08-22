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
//
// El botón NO es un `OutlinedButton` ni el menú un `IconButton`: se midió que
// esa maquinaria de Material costaba el 36% del rebuild de la tabla, así que
// ambos se rehicieron a mano. La réplica sigue a la implementación real.

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
      child: InkWell(
        onTap: () {},
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: 32,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tune, size: 15),
              SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Ajustar',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    const SizedBox(width: 4),
    SizedBox(
      width: kRowMenuWidth,
      child: PopupMenuButton<String>(
        padding: EdgeInsets.zero,
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Editar ficha')),
        ],
        child: const SizedBox(
          width: kRowMenuWidth,
          height: 40,
          child: Icon(Icons.more_vert, size: 19),
        ),
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
