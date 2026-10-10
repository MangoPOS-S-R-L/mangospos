// Formulario "Solicitar facturación electrónica".
//
// Lo que protege: que precargue lo que el cliente ya mandó (sucursales, tipos,
// usuario de la OFV), que nunca exija de nuevo una clave de la OFV ya
// guardada, que los requisitos nuevos se pidan en el orden del formulario y
// que quitar una sucursal no rompa los campos.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/ecf_request_repository.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/fiscal/view/ecf_request_dialog.dart';

const _company = {
  'rnc': '133328828',
  'legal_name': 'TROPELLA COFFEE SRL',
  'fiscal_address': 'Gregorio Luperón No. B 4, Gurabo',
  'province': 'Santiago',
  'municipality': 'Santiago de los Caballeros',
  'email': 'tropella@example.com',
};

Future<void> _open(WidgetTester tester, Map<String, dynamic> json) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showEcfRequestDialog(
              context,
              businessId: 'b1',
              status: EcfRequestStatus.fromJson(json),
            ),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
}

Future<void> _send(WidgetTester tester) async {
  await tester.tap(find.text('Enviar solicitud'));
  await tester.pumpAndSettle();
}

TextField _fieldLabeled(WidgetTester tester, String label) => tester.widget<TextField>(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      ),
    );

void main() {
  testWidgets('precarga sucursales, tipos y usuario de la OFV desde el RNC', (tester) async {
    await _open(tester, {
      'stage': 'company',
      'data': _company,
      'details': {
        'phone': '809-555-1234',
        'branches': [
          {'name': 'Real Food Park', 'address': 'Reparto Universitario'},
        ],
        'ecf_types': ['E32', 'E34'],
      },
    });

    expect(find.text('Real Food Park'), findsOneWidget);
    expect(find.text('Reparto Universitario'), findsOneWidget);
    final chips = tester.widgetList<FilterChip>(find.byType(FilterChip)).toList();
    expect(chips.length, ecfTypeCatalog.length);
    expect(
      [for (final c in chips) if (c.selected) (c.label as Text).data],
      ['E32 · Consumo', 'E34 · Nota de crédito'],
    );
    expect(_fieldLabeled(tester, 'Usuario').controller!.text, '133328828');
    expect(find.text('Clave'), findsOneWidget);
  });

  testWidgets('pide teléfono y representante legal antes que el certificado', (tester) async {
    await _open(tester, {'stage': 'none', 'data': _company});

    await _send(tester);
    expect(find.text('El teléfono de la empresa debe incluir el código de área.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Teléfono').first, '809-555-1234');
    await _send(tester);
    expect(find.text('Falta el nombre completo del representante legal.'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Nombre completo del representante legal'),
      'Ana Pérez',
    );
    await _send(tester);
    // Sin tipos elegidos (el servidor no sugirió ninguno).
    expect(find.text('Elige al menos un tipo de comprobante.'), findsOneWidget);

    await tester.tap(find.text('E32 · Consumo'));
    await tester.pumpAndSettle();
    await _send(tester);
    expect(find.text('Falta la clave de la Oficina Virtual de la DGII.'), findsOneWidget);
  });

  testWidgets('con la clave de la OFV ya guardada no la vuelve a pedir', (tester) async {
    await _open(tester, {
      'stage': 'company',
      'data': _company,
      'details': {
        'phone': '809-555-1234',
        'legal_rep_name': 'Ana Pérez',
        'ecf_types': ['E31', 'E32', 'E34'],
        'ofv_user': '133328828',
        'ofv_password_saved': true,
      },
    });

    expect(find.text('Clave (ya guardada)'), findsOneWidget);
    await _send(tester);
    expect(find.text('Falta tu certificado digital (.p12 o .pfx).'), findsOneWidget);
  });

  testWidgets('sucursal con nombre y sin dirección; quitarla no rompe', (tester) async {
    await _open(tester, {
      'stage': 'none',
      'data': _company,
      'details': {
        'phone': '809-555-1234',
        'legal_rep_name': 'Ana Pérez',
        'branches': [
          {'name': 'Centro', 'address': ''},
          {'name': 'Gurabo', 'address': 'Calle 1'},
        ],
      },
    });

    await _send(tester);
    expect(find.text('Falta la dirección de la sucursal Centro.'), findsOneWidget);

    await tester.tap(find.byTooltip('Quitar sucursal').first);
    await tester.pumpAndSettle();
    expect(find.text('Centro'), findsNothing);
    // La fila que queda conserva SUS datos.
    expect(find.text('Gurabo'), findsOneWidget);
    expect(find.text('Calle 1'), findsOneWidget);

    await tester.tap(find.text('Agregar sucursal'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Quitar sucursal'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  test('detalles: JSON de ida y vuelta, sin la clave', () {
    final d = EcfRequestDetails.fromJson({
      'phone': '809-555-1234',
      'legal_rep_name': 'Ana Pérez',
      'branches': [
        {'name': null, 'address': 'Calle 1'},
        'basura',
      ],
      'ecf_types': ['E31', 'E34'],
      'ofv_user': '133328828',
      'ofv_password_saved': true,
    });
    expect(d.branches.single.address, 'Calle 1');
    expect(d.ofvPasswordSaved, isTrue);
    final json = d.toJson();
    expect(json['ecf_types'], ['E31', 'E34']);
    expect(json.containsKey('ofv_password_saved'), isFalse);
    expect(json.keys.any((k) => k.contains('password')), isFalse);
    expect(const EcfRequestDetails().ecfTypes, isEmpty);
  });
}
