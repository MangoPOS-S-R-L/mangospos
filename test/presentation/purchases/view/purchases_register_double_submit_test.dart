// Candado del «Guardar» en el registro de compras.
//
// El caso real: dos toques rápidos en «Guardar» registraban la misma factura
// dos veces (la base le daba a la segunda el número siguiente sin quejarse).
// El botón volvía a quedar activo mientras se refrescaba el listado, se creaba
// la CxP y se imprimía la orden. Lo que se prueba acá:
//   - un segundo toque, en el mismo frame o después, no llega al servidor;
//   - la pantalla queda tapada con el paso en curso hasta salir de ella;
//   - si el guardado falla, el botón vuelve y el reintento manda la MISMA
//     llave de idempotencia (si el primero sí llegó, la base devuelve esa
//     compra en vez de crear otra).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/core/business/business_features_provider.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/data/repositories/purchases_repository.dart'
    show CreatedPurchaseOrder;
import 'package:mangopos/presentation/purchases/state/purchases_state.dart';
import 'package:mangopos/presentation/purchases/view/purchases_register_view.dart';
import 'package:mangopos/presentation/purchases/viewmodel/purchases_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// ViewModel de mentira: cada guardado espera a que la prueba lo suelte, así
/// se puede tocar «Guardar» otra vez con el primero todavía en vuelo.
class _FakePurchasesViewModel extends ChangeNotifier
    implements PurchasesViewModel {
  _FakePurchasesViewModel({this.detail});

  final PurchaseOrderDetail? detail;

  final List<String?> createKeys = [];
  final List<Completer<CreatedPurchaseOrder>> pendingCreates = [];
  int updateCalls = 0;
  final List<Completer<PurchaseOrderUpdateResult>> pendingUpdates = [];

  @override
  PurchasesState get state => PurchasesState(
    businessId: 'biz-1',
    suppliers: [
      PurchaseSupplier.fromMap({'id': 'sup-1', 'name': 'Bepensa'}),
    ],
    warehouses: [
      PurchaseWarehouse.fromMap({
        'id': 'wh-1',
        'name': 'Almacen Principal',
        'is_main': true,
      }),
    ],
    inventoryItems: [
      PurchaseInventoryItem.fromMap({
        'id': 'item-1',
        'name': 'Coca-Cola 12 oz',
        'sku': 'COCA-12',
        'unit': 'unidad',
        'cost': 45,
      }),
    ],
    orders: const [],
  );

  @override
  Future<void> init({bool force = false}) async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<String> generateNextOrderNumber() async => 'PO-00009';

  @override
  Future<bool> requiresGoodsReceipt() async => false;

  @override
  Future<PurchaseOrderDetail> loadOrderDetail(String orderId) async => detail!;

  @override
  Future<CreatedPurchaseOrder> createPurchaseOrder({
    required String supplierId,
    required String warehouseId,
    required String orderNumber,
    required String status,
    required DateTime expectedDate,
    String? notes,
    String? invoiceNumber,
    String? ncf,
    required List<PurchaseDraftItem> items,
    double discount = 0,
    String? idempotencyKey,
  }) {
    createKeys.add(idempotencyKey);
    final completer = Completer<CreatedPurchaseOrder>();
    pendingCreates.add(completer);
    return completer.future;
  }

  @override
  Future<PurchaseOrderUpdateResult> updatePurchaseOrder({
    required String orderId,
    required String supplierId,
    required String warehouseId,
    required DateTime expectedDate,
    required List<PurchaseDraftItem> items,
    required String idempotencyKey,
    String? notes,
    String? invoiceNumber,
    String? ncf,
    double discount = 0,
    String? reason,
  }) {
    updateCalls += 1;
    final completer = Completer<PurchaseOrderUpdateResult>();
    pendingUpdates.add(completer);
    return completer.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeSessionController extends SessionController {
  @override
  SessionState build() => const SessionState(
    permissions: {'compras.acceso', 'compras.ordenes.editar'},
  );
}

/// Compra pendiente (sin mercancía recibida): guardar la corrección no pide
/// confirmación, así el segundo toque cae directo sobre el botón.
PurchaseOrderDetail _pendingDetail() => PurchaseOrderDetail(
  order: PurchaseOrderSummary.fromMap(
    {
      'id': 'po-1',
      'supplier_id': 'sup-1',
      'warehouse_id': 'wh-1',
      'order_number': 'PO-00002',
      'invoice_number': 'P0344202',
      'status': 'sent',
      'total': 118,
      'created_at': '2026-08-27T14:08:00Z',
      'expected_date': '2026-08-29',
    },
    supplierName: 'Bepensa',
    warehouseName: 'Almacen Principal',
  ),
  subtotal: 100,
  tax: 18,
  discount: 0,
  lines: [
    PurchaseOrderLine.fromMap({
      'id': 'poi-9',
      'inventory_item_id': 'item-1',
      'description': 'Coca-Cola 12 oz',
      'quantity_ordered': 2,
      'quantity_received': 0,
      'unit_cost': 50,
      'tax_rate': 18,
      'total': 100,
    }),
  ],
);

Future<_FakePurchasesViewModel> _pump(
  WidgetTester tester, {
  PurchaseOrderDetail? editing,
}) async {
  tester.view.physicalSize = const Size(1500, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final vm = _FakePurchasesViewModel(detail: editing);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchasesViewModelProvider.overrideWith((ref) => vm),
        sessionProvider.overrideWith(_FakeSessionController.new),
        businessFeaturesProvider.overrideWith(
          (ref) async => BusinessFeatures.defaults,
        ),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: editing == null ? '/new' : '/edit',
          routes: [
            GoRoute(
              path: '/new',
              builder: (_, _) => const PurchasesRegisterView(),
            ),
            GoRoute(
              path: '/edit',
              builder: (_, _) =>
                  const PurchasesRegisterView(editOrderId: 'po-1'),
            ),
            GoRoute(
              path: '/settings/purchases/order/:id',
              builder: (_, _) =>
                  const Scaffold(body: Text('detalle de la compra')),
            ),
            GoRoute(
              path: '/settings/purchases',
              builder: (_, _) => const Scaffold(body: Text('compras')),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return vm;
}

/// Deja la factura lista para guardar: una línea (por SKU + Enter) y el
/// número de factura.
Future<void> _fillPurchase(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextField, 'Producto'),
    'COCA-12',
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextField, 'Ej. 0004521'), 'F-77');
  await tester.pumpAndSettle();
}

/// Mientras gira el spinner no hay `pumpAndSettle` que valga.
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('dos toques seguidos registran la compra UNA sola vez', (
    tester,
  ) async {
    final vm = await _pump(tester);
    await _fillPurchase(tester);

    final save = find.text('Guardar e ingresar stock');
    expect(save, findsOneWidget);

    // Los dos toques en el mismo frame: el botón todavía no se redibujó
    // deshabilitado cuando llega el segundo.
    await tester.tap(save);
    await tester.tap(save, warnIfMissed: false);
    await tester.pump();

    expect(vm.createKeys, hasLength(1));
    expect(find.text('Guardando compra…'), findsOneWidget);
    expect(find.text('Guardando…'), findsOneWidget);

    // Y un tercero ya con la pantalla tapada.
    await tester.tap(find.text('Guardando…'), warnIfMissed: false);
    await tester.pump();
    expect(vm.createKeys, hasLength(1));

    // La compra entra: la pantalla SIGUE tapada mientras sale el papel.
    vm.pendingCreates.single.complete(
      const CreatedPurchaseOrder(id: 'po-9', orderNumber: 'PO-00009'),
    );
    await _pumpFrames(tester);
    expect(find.text('Imprimiendo orden de compra…'), findsOneWidget);
    expect(vm.createKeys, hasLength(1));

    // Al cerrar el documento se va al listado.
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();
    expect(find.text('compras'), findsOneWidget);
    expect(vm.createKeys, hasLength(1));
  });

  testWidgets('si el guardado falla, el reintento manda la MISMA llave', (
    tester,
  ) async {
    final vm = await _pump(tester);
    await _fillPurchase(tester);

    await tester.tap(find.text('Guardar e ingresar stock'));
    await tester.pump();
    expect(vm.createKeys, hasLength(1));

    // Timeout del primero: el botón vuelve, y la pantalla se destapa.
    vm.pendingCreates.single.completeError(Exception('timeout'));
    await _pumpFrames(tester);
    expect(find.text('Guardando compra…'), findsNothing);

    await tester.tap(find.text('Guardar e ingresar stock'));
    await tester.pump();

    expect(vm.createKeys, hasLength(2));
    expect(vm.createKeys.first, isNotNull);
    expect(vm.createKeys.last, vm.createKeys.first);
  });

  testWidgets('dos toques en «Guardar cambios» corrigen UNA sola vez', (
    tester,
  ) async {
    final vm = await _pump(tester, editing: _pendingDetail());

    final save = find.text('Guardar cambios');
    expect(save, findsOneWidget);

    await tester.tap(save);
    await tester.tap(save, warnIfMissed: false);
    await tester.pump();

    expect(vm.updateCalls, 1);
    expect(find.text('Guardando cambios…'), findsOneWidget);

    vm.pendingUpdates.single.complete(
      const PurchaseOrderUpdateResult(
        orderId: 'po-1',
        status: 'sent',
        total: 118,
        movementsCreated: 0,
        payableAdjusted: false,
        replayed: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('detalle de la compra'), findsOneWidget);
    expect(vm.updateCalls, 1);
  });
}
