// Salidas / Mermas: el historial se filtra por motivo, suma lo filtrado y el
// A4 imprime exactamente lo que se está viendo.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/view/widgets/outflow_history_section.dart';

InventoryMovementEntry _m(
  String id, {
  double qty = -1,
  String? reason,
  String notes = '',
  String ref = 'manual_outflow',
  double cost = 50,
}) => InventoryMovementEntry.fromMap(
  {
    'id': id,
    'item_id': 'leche',
    'warehouse_id': 'w',
    'movement_type': 'waste',
    'quantity': qty,
    'cost_per_unit': cost,
    'notes': notes,
    'reference_type': ref,
    'reason_code': reason,
    'created_at': '2026-09-30T15:00:00Z',
  },
  itemName: 'Leche',
  warehouseName: 'Principal',
);

void main() {
  late List<int> requestedDays;
  late List<List<InventoryMovementEntry>> printed;

  Future<void> pump(WidgetTester tester) async {
    requestedDays = [];
    printed = [];
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: OutflowHistorySection(
              reloadKey: 'k',
              load: (days) async {
                requestedDays.add(days);
                return [
                  _m(
                    'a',
                    qty: -2,
                    reason: 'expiration',
                    notes: 'Vencido — nevera',
                  ),
                  _m('b', reason: 'expiration'),
                  _m('c', notes: 'Rotura / dañado — caja'),
                  _m('d', ref: 'order_item_removal', notes: 'Merma: devuelto'),
                ];
              },
              itemsById: const {},
              money: BusinessCurrency.fallbackDop,
              onPrintTicket: (_) async {},
              onPrintA4: (list) async => printed.add(list),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('chips por motivo con su cuenta', (tester) async {
    await pump(tester);
    expect(requestedDays, [7]);
    expect(find.text('Todos · 4'), findsOneWidget);
    expect(find.text('Vencido · 2'), findsOneWidget);
    expect(find.text('Rotura / dañado · 1'), findsOneWidget);
    expect(find.text('Quitado de la cuenta · 1'), findsOneWidget);
  });

  testWidgets('filtrar por motivo suma solo eso y el A4 imprime lo filtrado', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('outflow-reason-expiration')));
    await tester.pumpAndSettle();

    final summary = tester.widget<Text>(
      find.byKey(const Key('outflow-history-summary')),
    );
    // 2 salidas: 2 × 50 + 1 × 50 = 150.
    expect(summary.data, contains('2 salidas'));
    expect(summary.data, contains('150'));
    expect(summary.data, contains('Vencido'));
    expect(find.byKey(const ValueKey('outflow-history-c')), findsNothing);

    await tester.tap(find.byKey(const Key('outflow-history-a4')));
    await tester.pumpAndSettle();
    expect(printed.single.map((m) => m.id), ['a', 'b']);
  });

  testWidgets('cambiar el período vuelve a leer', (tester) async {
    await pump(tester);
    await tester.tap(find.text('30 días'));
    await tester.pumpAndSettle();
    expect(requestedDays, [7, 30]);
  });
}
