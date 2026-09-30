// Registrar una salida / merma desde Inventario → Salidas / Mermas.
//
// Lo que se cuida acá, todo salido de la auditoría del 2026-09-30:
//   - desde el encabezado NO hay insumo preseleccionado (antes quedaba el
//     primero de la lista y se descontaba el equivocado);
//   - la selección sigue a la búsqueda;
//   - la cantidad acepta coma decimal y la unidad de compra (botella → ml);
//   - una salida mayor que la existencia pide confirmación;
//   - un reintento tras un error manda la MISMA llave (no resta dos veces).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/view/inventory_outflow_view.dart';
import 'package:mangopos/presentation/inventory/viewmodel/inventory_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

class _Call {
  _Call(this.itemId, this.quantity, this.reasonCode, this.operationId, this.cost);
  final String itemId;
  final double quantity;
  final String reasonCode;
  final String operationId;
  final double? cost;
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
  }) async {
    calls.add(_Call(itemId, quantity, reasonCode, operationId, costPerUnit));
    if (failuresLeft > 0) {
      failuresLeft -= 1;
      throw Exception('Timeout');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
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
}) => InventoryItemSummary.fromMap({
  'id': id,
  'name': name,
  'unit': unit,
  'purchase_unit': purchaseUnit,
  'pack_size': packSize,
  'cost': cost,
}, stock: stock);

InventoryState _state() => InventoryState(
  // Sin negocio: la prueba no llega a imprimir el conduce (eso toca
  // impresoras reales).
  businessId: null,
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
  ],
);

Future<_FakeInventoryVm> _pump(
  WidgetTester tester, {
  Set<String> perms = const {
    'inventario.acceso',
    'inventario.ajustes.crear',
    'inventario.productos.crear_editar',
  },
}) async {
  tester.view.physicalSize = const Size(1500, 1100);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final vm = _FakeInventoryVm(_state());
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
}
