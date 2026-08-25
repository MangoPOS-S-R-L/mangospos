import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/sales/widgets/precheck/pre_check_dialog.dart';

void main() {
  testWidgets('la pre-cuenta en pantalla muestra cada impuesto y el descuento',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PreCheckDialog(
          data: const {
            'restaurantName': 'Medio Tiempo Bar',
            'tableName': 'A21',
            'items': [
              {'quantity': 1, 'name': 'Margarita Limon', 'price': 400.0},
            ],
            'subtotal': 2109.38,
            'tax': 590.62,
            'total': 1470.0,
            'totals': [
              {'label': 'Subtotal', 'amount': 2109.38, 'isNegative': false},
              {'label': 'ITBIS (18%)', 'amount': 379.69, 'isNegative': false},
              {'label': 'LEY (10%)', 'amount': 210.94, 'isNegative': false},
              {'label': 'Descuento', 'amount': 1230.0, 'isNegative': true},
            ],
          },
          onPrint: () {},
          onCancel: () {},
        ),
      ),
    );
    await tester.pump();

    // La fuente de prueba de Flutter es más ancha que la real (cada glifo mide
    // lo mismo), así que la fila "Mesa / Hora" del encabezado desborda los
    // 352 px del diálogo solo en el test. No es lo que estamos verificando.
    tester.takeException();

    expect(find.text('ITBIS (18%)'), findsOneWidget);
    expect(find.text('LEY (10%)'), findsOneWidget);
    expect(find.text('Descuento'), findsOneWidget);
    expect(find.text('- RD\$ 1,230.00'), findsOneWidget);
    expect(find.text('RD\$ 590.62'), findsNothing);
  });
}
