import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/inventory/unit_conversion.dart';
import 'package:mangopos/presentation/inventory/view/widgets/unit_dropdown.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 280, child: child)),
      ),
    );

void main() {
  test('un widget cerrado por cada ítem, y ningún valor repetido', () {
    // DropdownButton revienta si dos ítems comparten valor o si el
    // selectedItemBuilder no trae exactamente un widget por ítem.
    final casos = <List<UnitSection>>[
      baseUnitSections(),
      baseUnitSections(current: 'bolsa'),
      purchaseUnitSections(),
      purchaseUnitSections(current: 'manojo'),
    ];
    for (final sections in casos) {
      final items = unitDropdownItems(sections, emptyLabel: 'Sin empaque');
      final values = items.map((i) => i.value).toList();
      expect(values.toSet(), hasLength(values.length));
      // El builder no usa el context: basta con contar lo que devuelve.
      final built = unitDropdownSelectedBuilder(
        sections,
        emptyLabel: 'Sin empaque',
      )(_FakeContext());
      expect(built, hasLength(items.length));
    }

    final options = unitOptionsFor(baseUnit: 'ml', purchaseUnit: 'Botella');
    expect(unitOptionItems(options), hasLength(options.length));
    expect(unitOptionSelectedBuilder(options)(_FakeContext()),
        hasLength(options.length));
  });

  testWidgets('una base fuera del catálogo se ve y se puede cambiar por libra',
      (tester) async {
    final sections = baseUnitSections(current: 'bolsa');
    String? picked;
    await tester.pumpWidget(_host(
      DropdownButtonFormField<String>(
        initialValue: unitSelectionValue(sections, 'bolsa', fallback: 'unidad'),
        isExpanded: true,
        items: unitDropdownItems(sections),
        selectedItemBuilder: unitDropdownSelectedBuilder(sections),
        onChanged: (v) => picked = v,
      ),
    ));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('ACTUAL'), findsOneWidget);
    expect(find.text('PESO'), findsOneWidget);
    expect(find.text('bolsa (actual)'), findsOneWidget);

    await tester.tap(find.text('Libra (lb)').last);
    await tester.pumpAndSettle();
    expect(picked, 'lb');
    expect(tester.takeException(), isNull);
  });

  testWidgets('los títulos de clase no se pueden elegir', (tester) async {
    final sections = baseUnitSections();
    String? picked;
    await tester.pumpWidget(_host(
      DropdownButtonFormField<String>(
        initialValue: 'unidad',
        isExpanded: true,
        items: unitDropdownItems(sections),
        selectedItemBuilder: unitDropdownSelectedBuilder(sections),
        onChanged: (v) => picked = v,
      ),
    ));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    // El menú abre desplazado hasta lo seleccionado («unidad», en Conteo) y
    // solo construye las filas visibles: se toca el título de al lado.
    await tester.tap(find.text('CONTEO').last);
    await tester.pumpAndSettle();
    expect(picked, isNull);
  });

  testWidgets('compra guardada como «CAJAS» arranca en Caja y admite quitarla',
      (tester) async {
    final sections = purchaseUnitSections(current: 'CAJAS');
    final initial = unitSelectionValue(sections, 'CAJAS', fallback: '');
    expect(initial, 'Caja');

    String? picked;
    await tester.pumpWidget(_host(
      DropdownButtonFormField<String>(
        initialValue: initial,
        isExpanded: true,
        items: unitDropdownItems(sections, emptyLabel: 'Sin empaque'),
        selectedItemBuilder: unitDropdownSelectedBuilder(
          sections,
          emptyLabel: 'Sin empaque',
        ),
        onChanged: (v) => picked = v,
      ),
    ));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('Caja (CS)'), findsWidgets);
    await tester.tap(find.text('Sin empaque').last);
    await tester.pumpAndSettle();
    expect(picked, '');
  });
}

class _FakeContext extends Fake implements BuildContext {}
