// Registrar una salida / merma desde Inventario → Salidas / Mermas.
//
// Lo que se cuida acá, todo salido de la auditoría del 2026-09-30:
//   - desde el encabezado NO hay insumo preseleccionado (antes quedaba el
//     primero de la lista y se descontaba el equivocado);
//   - la selección sigue a la búsqueda;
//   - la cantidad acepta coma decimal y la unidad de compra (botella → ml);
//   - una salida mayor que la existencia pide confirmación;
//   - un reintento tras un error manda la MISMA llave (no resta dos veces).
//
// Gastables y menaje (2026-09-30): la clase del insumo propone el motivo (un
// gastable sale por consumo interno, el menaje por rotura) y el consumo
// interno pide el área a la que va.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/view/inventory_outflow_view.dart';
import 'package:mangopos/presentation/inventory/viewmodel/inventory_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

class _Call {
  _Call(
    this.itemId,
    this.quantity,
    this.reasonCode,
    this.operationId,
    this.cost,
    this.destination,
  );
  final String itemId;
  final double quantity;
  final String reasonCode;
  final String operationId;
  final double? cost;
  final String? destination;
}

class _FakeInventoryVm extends ChangeNotifier implements InventoryViewModel {
  _FakeInventoryVm(this._state);

  final InventoryState _state;
  final calls = <_Call>[];
  int failuresLeft = 0;

  @override
  InventoryState get state => _state;

  @override
  Future<void> init({bool force = false}) async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> registerOutflow({
    required String itemId,
    required double quantity,
    required String reasonCode,
    required String reasonLabel,
    required String operationId,
    double? costPerUnit,
    String? notes,
    String? destination,
  }) async {
    calls.add(
      _Call(itemId, quantity, reasonCode, operationId, costPerUnit, destination),
    );
    if (failuresLeft > 0) {
      failuresLeft -= 1;
      throw Exception('Timeout');
    }
  }

  /// Salidas que devuelve la ficha del insumo, y los períodos pedidos.
  List<InventoryMovementEntry> outflows = const [];
  final requestedDays = <int>[];

  @override
  Future<List<InventoryMovementEntry>> loadItemOutflows(
    String itemId, {
    int days = 30,
  }) async {
    requestedDays.add(days);
    return outflows.where((m) => m.itemId == itemId).toList();
  }

  @override
  /// Historial de Salidas y mermas (filtro por motivo).
  List<InventoryMovementEntry> history = const [];

  @override
  Future<List<InventoryMovementEntry>> loadOutflowHistory({
    int days = 7,
  }) async => history;

  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session extends SessionController {
  _Session(this.perms);
  final Set<String> perms;

  @override
  SessionState build() => SessionState(permissions: perms);
}

InventoryItemSummary _item(
  String id,
  String name,
  String unit,
  double stock, {
  String purchaseUnit = '',
  double packSize = 1,
  double cost = 10,
  String classification = 'simple',
}) => InventoryItemSummary.fromMap({
  'id': id,
  'name': name,
  'unit': unit,
  'purchase_unit': purchaseUnit,
  'pack_size': packSize,
  'cost': cost,
  'item_classification': classification,
}, stock: stock);

InventoryState _state({String? businessId}) => InventoryState(
  // Sin negocio: la prueba no llega a preguntar por el conduce (imprimir
  // toca impresoras reales). Las pruebas de la pregunta ponen uno.
  businessId: businessId,
  selectedWarehouseId: 'wh-1',
  warehouses: const [
    InventoryWarehouse(id: 'wh-1', name: 'Principal', isMain: true),
    InventoryWarehouse(id: 'wh-t', name: '__IN_TRANSIT__', isMain: false),
  ],
  items: [
    _item('i-leche', 'Leche', 'l', 10, cost: 50),
    _item('i-queso', 'Queso', 'lb', 3),
    _item(
      'i-ron',
      'Ron Barcelo',
      'ml',
      1500,
      purchaseUnit: 'botella',
      packSize: 750,
    ),
    _item('i-papel', 'Papel higiénico', 'rollo', 96, classification: 'supply'),
    _item('i-copa', 'Copa de vino', 'u', 120, classification: 'smallware'),
  ],
);

Future<_FakeInventoryVm> _pump(
  WidgetTester tester, {
  Set<String> perms = const {
    'inventario.acceso',
    'inventario.ajustes.crear',
    'inventario.productos.crear_editar',
  },
  String? businessId,
}) async {
  tester.view.physicalSize = const Size(1500, 1100);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final vm = _FakeInventoryVm(_state(businessId: businessId));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inventoryViewModelProvider.overrideWith((ref) => vm),
        sessionProvider.overrideWith(() => _Session(perms)),
      ],
      child: const MaterialApp(home: InventoryOutflowView()),
    ),
  );
  await tester.pumpAndSettle();
  return vm;
}

final _dialog = find.byType(AlertDialog);
Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('outflow-open')));
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(_inDialog(find.byType(TextField)).first, text);
  await tester.pumpAndSettle();
}

Future<void> _quantity(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('outflow-quantity')), text);
  await tester.pump();
}

Future<void> _reason(WidgetTester tester, String label) async {
  await tester.tap(_inDialog(find.text(label)));
  await tester.pump();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('outflow-submit')));
  await tester.pumpAndSettle();
}

String _banner(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('outflow-selected'))).data ?? '';

void main() {
  testWidgets('sin permiso de ajustes no se puede abrir la salida', (
    tester,
  ) async {
    await _pump(tester, perms: const {'inventario.acceso'});
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('outflow-open')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('la bodega virtual de tránsito no aparece en el selector', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.textContaining('__IN_TRANSIT__'), findsNothing);
  });

  testWidgets('desde el encabezado no hay insumo elegido y no deja registrar', (
    tester,
  ) async {
    final vm = await _pump(tester);
    await _open(tester);

    expect(_banner(tester), contains('Toca en la lista'));
    await _quantity(tester, '1');
    await _reason(tester, 'Vencido');
    await _submit(tester);

    expect(vm.calls, isEmpty);
    expect(find.text('Elige en la lista el insumo que salió'), findsOneWidget);
  });

  testWidgets('la selección sigue a la búsqueda', (tester) async {
    await _pump(tester);
    await _open(tester);

    // Un solo resultado: queda elegido.
    await _search(tester, 'ques');
    expect(_banner(tester), contains('Insumo: Queso'));

    // La búsqueda lo escondió: deja de estar elegido.
    await _search(tester, 'leche x');
    expect(_banner(tester), contains('Toca en la lista'));
  });

  testWidgets('acepta coma decimal y manda costo y llave', (tester) async {
    final vm = await _pump(tester);
    await _open(tester);
    await _search(tester, 'leche');
    await _quantity(tester, '2,5');
    await _reason(tester, 'Vencido');
    await _submit(tester);

    expect(vm.calls, hasLength(1));
    final call = vm.calls.single;
    expect(call.itemId, 'i-leche');
    expect(call.quantity, 2.5);
    expect(call.reasonCode, 'expiration');
    expect(call.cost, 50);
    expect(call.operationId, isNotEmpty);
    expect(_dialog, findsNothing);
  });

  testWidgets('en botellas convierte a ml', (tester) async {
    final vm = await _pump(tester);
    await _open(tester);
    await _search(tester, 'ron');
    await tester.tap(_inDialog(find.text('botella')));
    await tester.pump();
    await _quantity(tester, '2');
    expect(find.text('= 1500 ml'), findsOneWidget);
    await _reason(tester, 'Rotura / dañado');
    await _submit(tester);

    expect(vm.calls.single.quantity, 1500);
  });

  testWidgets('más que la existencia pide confirmación', (tester) async {
    final vm = await _pump(tester);
    await _open(tester);
    await _search(tester, 'queso');
    await _quantity(tester, '5');
    await _reason(tester, 'Faltante / robo');
    await _submit(tester);

    expect(find.text('La salida es mayor que la existencia'), findsOneWidget);
    await tester.tap(find.text('Revisar'));
    await tester.pumpAndSettle();
    expect(vm.calls, isEmpty);

    await _submit(tester);
    await tester.tap(find.byKey(const Key('outflow-overstock-confirm')));
    await tester.pumpAndSettle();
    expect(vm.calls, hasLength(1));
    expect(vm.calls.single.quantity, 5);
  });

  testWidgets('un reintento tras un error manda la MISMA llave', (
    tester,
  ) async {
    final vm = await _pump(tester);
    vm.failuresLeft = 1;
    await _open(tester);
    await _search(tester, 'leche');
    await _quantity(tester, '1');
    await _reason(tester, 'Vencido');

    await _submit(tester);
    expect(find.textContaining('no se descontará dos veces'), findsOneWidget);
    expect(_dialog, findsOneWidget);

    await _submit(tester);
    expect(vm.calls, hasLength(2));
    expect(vm.calls[0].operationId, vm.calls[1].operationId);
    expect(_dialog, findsNothing);
  });

  testWidgets('al guardar PREGUNTA si imprimir (ticket, A4 o nada)', (
    tester,
  ) async {
    final vm = await _pump(tester, businessId: 'biz-1');
    await _open(tester);
    await _search(tester, 'leche');
    await _quantity(tester, '2');
    await _reason(tester, 'Vencido');
    await _submit(tester);

    expect(vm.calls, hasLength(1));
    expect(find.text('Salida registrada'), findsOneWidget);
    expect(
      find.textContaining('Se descontaron 2 l de Leche (Vencido)'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('outflow-print-ticket')), findsOneWidget);
    expect(find.byKey(const Key('outflow-print-a4')), findsOneWidget);

    await tester.tap(find.byKey(const Key('outflow-print-none')));
    await tester.pumpAndSettle();
    expect(find.text('Salida registrada'), findsNothing);
  });

  group('gastables y menaje', () {
    Finder chip(String label) =>
        _inDialog(find.widgetWithText(ChoiceChip, label));
    bool selected(WidgetTester tester, String label) =>
        tester.widget<ChoiceChip>(chip(label)).selected;

    testWidgets('un gastable propone Consumo interno y manda el área', (
      tester,
    ) async {
      final vm = await _pump(tester);
      await _open(tester);
      await _search(tester, 'papel');

      expect(selected(tester, 'Consumo interno'), isTrue);
      expect(find.byKey(const Key('outflow-destination')), findsOneWidget);

      await _quantity(tester, '12');
      await tester.tap(chip('Baños'));
      await tester.pump();
      await _submit(tester);

      final call = vm.calls.single;
      expect(call.itemId, 'i-papel');
      expect(call.reasonCode, 'internal_use');
      expect(call.destination, 'Baños');
    });

    testWidgets('el área es texto libre y opcional', (tester) async {
      final vm = await _pump(tester);
      await _open(tester);
      await _search(tester, 'papel');
      await _quantity(tester, '2');
      await _submit(tester);
      expect(vm.calls.single.destination, isNull);
    });

    testWidgets('el menaje propone Rotura y no pide área', (tester) async {
      final vm = await _pump(tester);
      await _open(tester);
      await _search(tester, 'copa');

      expect(selected(tester, 'Rotura / dañado'), isTrue);
      expect(find.byKey(const Key('outflow-destination')), findsNothing);

      await _quantity(tester, '3');
      await _submit(tester);
      expect(vm.calls.single.reasonCode, 'breakage');
    });

    testWidgets('lo que elige la persona no se pisa al cambiar de insumo', (
      tester,
    ) async {
      final vm = await _pump(tester);
      await _open(tester);
      await _search(tester, 'copa');
      await _reason(tester, 'Faltante / robo');
      await _search(tester, 'papel');

      expect(selected(tester, 'Faltante / robo'), isTrue);
      await _quantity(tester, '1');
      await _submit(tester);
      expect(vm.calls.single.reasonCode, 'theft');
    });

    testWidgets('el área solo viaja con Consumo interno', (tester) async {
      final vm = await _pump(tester);
      await _open(tester);
      await _search(tester, 'papel');
      await tester.enterText(
        find.byKey(const Key('outflow-destination')),
        'Cocina',
      );
      await _reason(tester, 'Rotura / dañado');
      await _quantity(tester, '1');
      await _submit(tester);

      expect(vm.calls.single.reasonCode, 'breakage');
      expect(vm.calls.single.destination, isNull);
    });

    testWidgets('un insumo de comida no propone motivo', (tester) async {
      final vm = await _pump(tester);
      await _open(tester);
      await _search(tester, 'leche');
      await _quantity(tester, '1');
      await _submit(tester);
      expect(vm.calls, isEmpty);
      expect(find.text('Selecciona el motivo de la salida'), findsOneWidget);
    });
  });

  group('ficha del insumo', () {
    InventoryMovementEntry outflow(String id, double qty, String notes) =>
        InventoryMovementEntry.fromMap(
          {
            'id': id,
            'item_id': 'i-leche',
            'warehouse_id': 'wh-1',
            'movement_type': 'waste',
            'quantity': -qty,
            'cost_per_unit': 48,
            'notes': notes,
            'reference_type': 'manual_outflow',
            'created_at': '2026-09-30T01:15:00Z',
          },
          itemName: 'Leche',
          warehouseName: 'Principal',
        );

    testWidgets('tocar la fila abre sus salidas, cada una imprimible', (
      tester,
    ) async {
      final vm = await _pump(tester, businessId: 'biz-1');
      vm.outflows = [
        outflow('m1', 2.5, 'Vencido — nevera 2'),
        outflow('m2', 1, 'Rotura / dañado'),
      ];

      await tester.tap(find.byKey(const ValueKey('outflow-row-i-leche')));
      await tester.pumpAndSettle();

      expect(vm.requestedDays, [30]);
      expect(find.text('−2.5 l · Vencido'), findsOneWidget);
      expect(find.text('−1 l · Rotura / dañado'), findsOneWidget);
      // 01:15 UTC = 21:15 del día anterior en RD.
      expect(find.text('29/09/2026 21:15 · nevera 2'), findsOneWidget);
      for (final id in ['m1', 'm2']) {
        expect(find.byKey(ValueKey('item-outflow-ticket-$id')), findsOneWidget);
        expect(find.byKey(ValueKey('item-outflow-a4-$id')), findsOneWidget);
      }
      final printAll = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('item-outflows-print-all')),
      );
      expect(printAll.onPressed, isNotNull);

      // Cambiar el período vuelve a pedir.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Hoy'),
        ),
      );
      await tester.pumpAndSettle();
      expect(vm.requestedDays, [30, 1]);
    });

    testWidgets('el botón de imprimir de la fila abre la misma ficha', (
      tester,
    ) async {
      final vm = await _pump(tester, businessId: 'biz-1');
      await tester.tap(find.byKey(const ValueKey('outflow-print-i-queso')));
      await tester.pumpAndSettle();

      expect(vm.requestedDays, [30]);
      expect(
        find.text('Este insumo no tiene salidas en los últimos 30 días.'),
        findsOneWidget,
      );
      final printAll = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('item-outflows-print-all')),
      );
      expect(printAll.onPressed, isNull);
    });

    testWidgets('«Registrar salida» abre el diálogo con ESE insumo elegido', (
      tester,
    ) async {
      await _pump(tester, businessId: 'biz-1');
      await tester.tap(find.byKey(const ValueKey('outflow-row-i-queso')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Registrar salida'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Registrar salida de inventario'), findsOneWidget);
      expect(_banner(tester), contains('Insumo: Queso'));
    });
  });
}
