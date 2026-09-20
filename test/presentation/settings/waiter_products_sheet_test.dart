// Desglose de productos por mozo (pantalla Mozos, /ajustes/mozos).
//
// Lo que se prueba es la agrupación: la hoja recibe items sueltos de
// varias mesas y tiene que mostrar UNA línea por producto, con las
// unidades y el dinero sumados, ordenadas de mayor a menor. Si eso se
// rompe el dueño ve el mismo producto repetido y un total que no cuadra.
//
// La pestaña "Cobrado" pide sus items a la base; aquí se monta sin
// órdenes cobradas, así que no toca Supabase y las pruebas quedan sobre
// la pestaña "Pendiente", que trae los items ya cargados.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/users/view/waiter_products_sheet.dart';

OrderItem _item({
  required String id,
  required String name,
  required double qty,
  required double total,
  String orderId = 'order-1',
  String? sku,
}) {
  return OrderItem(
    id: id,
    orderId: orderId,
    productName: name,
    sku: sku,
    quantity: qty,
    unitPrice: qty == 0 ? 0 : total / qty,
    subtotal: total,
    discounts: 0,
    tax: 0,
    total: total,
    isTakeout: false,
    status: 'served',
    createdAt: DateTime(2026, 9, 19, 12),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required List<OrderItem> pendingItems,
  double paidTotal = 0,
  double pendingTotal = 0,
}) async {
  tester.view.physicalSize = const Size(1024, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: WaiterProductsSheet(
          waiterName: 'Claudia Pérez',
          initials: 'CP',
          paidOrderIds: const [],
          pendingItems: pendingItems,
          paidTotal: paidTotal,
          pendingTotal: pendingTotal,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Pendiente'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('agrupa el mismo producto de varias mesas en una sola línea', (
    tester,
  ) async {
    await _pump(
      tester,
      pendingItems: [
        _item(id: '1', name: 'Presidente', qty: 2, total: 400),
        _item(id: '2', name: 'Presidente', qty: 3, total: 600, orderId: 'o2'),
        _item(id: '3', name: 'Mofongo', qty: 1, total: 350),
      ],
      pendingTotal: 1350,
    );

    expect(find.text('Presidente'), findsOneWidget);
    expect(find.text('Mofongo'), findsOneWidget);
    // 5 cervezas en total, no dos líneas de 2 y 3.
    expect(find.text('5 x'), findsOneWidget);
    expect(find.text('RD\$ 1,000.00'), findsOneWidget);
  });

  testWidgets('ordena de mayor a menor y totaliza al pie', (tester) async {
    await _pump(
      tester,
      pendingItems: [
        _item(id: '1', name: 'Agua', qty: 1, total: 100),
        _item(id: '2', name: 'Mofongo', qty: 2, total: 700),
        _item(id: '3', name: 'Presidente', qty: 4, total: 800),
      ],
      pendingTotal: 1600,
    );

    final names = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .where((t) => t == 'Agua' || t == 'Mofongo' || t == 'Presidente')
        .toList();
    expect(names, ['Presidente', 'Mofongo', 'Agua']);

    expect(find.text('3 productos · 7 unidades'), findsOneWidget);
    // El monto sale dos veces: en la pestaña "Pendiente" y en el pie.
    expect(find.text('RD\$ 1,600.00'), findsNWidgets(2));
  });

  testWidgets('suma unidades fraccionadas sin redondear de más', (
    tester,
  ) async {
    await _pump(
      tester,
      pendingItems: [
        _item(id: '1', name: 'Pizza familiar', qty: 0.5, total: 250),
        _item(id: '2', name: 'Pizza familiar', qty: 0.25, total: 125),
      ],
      pendingTotal: 375,
    );

    expect(find.text('0.75 x'), findsOneWidget);
    // Pestaña, línea del producto y pie.
    expect(find.text('RD\$ 375.00'), findsNWidgets(3));
  });

  testWidgets('mozo sin nada por cobrar muestra el estado vacío', (
    tester,
  ) async {
    await _pump(tester, pendingItems: const []);

    expect(
      find.text('Este mozo no tiene productos por cobrar.'),
      findsOneWidget,
    );
  });
}
