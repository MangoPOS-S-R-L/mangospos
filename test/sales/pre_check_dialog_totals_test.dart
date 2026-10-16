import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/sales/widgets/precheck/pre_check_dialog.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/utils/precheck_item_payload.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';

List<OrderItem> _mesa82() => [
  for (final (qty, discount) in [(2.0, 0.0), (4.0, 250.0)])
    OrderItem.fromMap({
      'id': 'item-$qty',
      'order_id': 'order',
      'product_name': '4×3 Presidente Normal',
      'qty': qty,
      'unit_price': 250.0,
      'subtotal': double.parse((qty * 250 / 1.28).toStringAsFixed(2)),
      'tax': qty * 250 - double.parse((qty * 250 / 1.28).toStringAsFixed(2)),
      'discounts': discount,
      'tax_mode': 'inclusive',
      'tax_rate': 28.0,
      'notes': '[DEAL:promo]\n[DEAL_RULE:4:250.00]',
    }),
];

Map<String, dynamic> _mesa82Data() {
  final rows = _mesa82();
  final summary = summarizeOrderPricing(null, rows);
  return {
    'restaurantName': 'MangoPOS S.R.L.',
    'tableName': 'MESA82',
    'waiterName': 'Admin',
    'rnc': '1-3367934-5',
    'phone': '8098618985',
    'items': buildPrecheckItemPayload(null, rows),
    'subtotal': summary.subtotal,
    'tax': summary.tax,
    'total': summary.total,
    'totals':
        buildReceiptTotalsRows(
              summary: summary,
              postDiscountMode: true,
              taxBreakdown: const [
                (label: '10% De Ley (10%)', amount: 117.19),
                (label: 'ITBIS (18%)', amount: 210.94),
              ],
            )
            .map(
              (r) => {
                'label': r.label,
                'amount': r.amount,
                'isNegative': r.isNegative,
              },
            )
            .toList(),
  };
}

void main() {
  for (final width in [800.0, 390.0, 360.0]) {
    testWidgets(
      'MESA82 a $width px: importes netos sin multiplicar y sin desbordes',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: PreCheckDialog(
              data: _mesa82Data(),
              onPrint: () {},
              onCancel: () {},
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('RD\$ 500.00'), findsOneWidget);
        expect(find.text('RD\$ 750.00'), findsOneWidget);
        expect(find.text('RD\$ 1,000.00'), findsNothing);
        expect(find.text('RD\$ 3,000.00'), findsNothing);
        expect(find.text('RD\$ 1,250.00'), findsOneWidget);
        final total = tester.getRect(find.text('RD\$ 1,250.00'));
        final printButton = tester.getRect(find.byType(ElevatedButton));
        expect(total.bottom, lessThan(printButton.top));
        expect(find.text('2'), findsOneWidget);
        expect(find.text('4'), findsOneWidget);
        expect(find.text('Descuento incluido'), findsOneWidget);
        expect(find.text('IMPORTE'), findsOneWidget);
      },
    );
  }
  testWidgets(
    'separar unidades mantiene exactamente el importe con descuento',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PreCheckDialog(
            data: {
              ..._mesa82Data(),
              'items': [
                {
                  'quantity': 3,
                  'name': 'Producto',
                  'price': 100 / 3,
                  'lineTotal': 100.0,
                },
              ],
            },
            receiptItemDisplayMode: 'separate',
            onPrint: () {},
            onCancel: () {},
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('RD\$ 33.34'), findsOneWidget);
      expect(find.text('RD\$ 33.33'), findsNWidgets(2));
    },
  );
  test(
    'los importes del payload incluyen los impuestos también en precios exclusivos',
    () {
      final item = OrderItem.fromMap({
        'qty': 2.0,
        'unit_price': 250.0,
        'subtotal': 500.0,
        'tax': 90.0,
        'discounts': 0.0,
        'tax_rate': 18.0,
        'tax_mode': 'exclusive',
      });
      final payload = buildPrecheckItemPayload(null, [item]).single;
      expect(payload['price'], 295);
      expect(payload['lineTotal'], 590);
    },
  );
  testWidgets(
    'la pre-cuenta en pantalla muestra cada impuesto y el descuento',
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

      expect(tester.takeException(), isNull);

      expect(find.text('ITBIS (18%)'), findsOneWidget);
      expect(find.text('LEY (10%)'), findsOneWidget);
      expect(find.text('Descuento'), findsOneWidget);
      expect(find.text('- RD\$ 1,230.00'), findsOneWidget);
      expect(find.text('RD\$ 590.62'), findsNothing);
    },
  );
}
