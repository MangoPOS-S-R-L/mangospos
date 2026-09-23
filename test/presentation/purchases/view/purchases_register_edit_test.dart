// Corrección de una compra ya registrada, desde la pantalla de registro.
//
// Lo que se prueba acá es el IDA Y VUELTA: una compra guardada se reabre en
// los mismos campos con los que se registró, y al guardar sin tocar nada el
// servidor recibe exactamente lo mismo que ya tenía. Si eso se rompe, editar
// el NCF de una factura movería el inventario sin que nadie lo pidiera.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/core/business/business_features_provider.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/presentation/purchases/state/purchases_state.dart';
import 'package:mangopos/presentation/purchases/view/purchases_register_view.dart';
import 'package:mangopos/presentation/purchases/viewmodel/purchases_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// ViewModel de mentira: guarda lo que la pantalla mandó a corregir para
/// poder revisarlo, sin tocar Supabase.
class _FakePurchasesViewModel extends ChangeNotifier
    implements PurchasesViewModel {
  _FakePurchasesViewModel(this._detail);

  final PurchaseOrderDetail _detail;

  List<PurchaseDraftItem>? sentItems;
  String? sentSupplierId;
  String? sentWarehouseId;
  String? sentInvoiceNumber;
  String? sentNcf;
  String? sentReason;
  double? sentDiscount;
  int updateCalls = 0;

  @override
  PurchasesState get state => PurchasesState(
    businessId: 'biz-1',
    suppliers: [
      PurchaseSupplier.fromMap({'id': 'sup-1', 'name': 'Bepensa'}),
      PurchaseSupplier.fromMap({'id': 'sup-2', 'name': 'Peralta'}),
    ],
    warehouses: [
      PurchaseWarehouse.fromMap({
        'id': 'wh-1',
        'name': 'Almacen Principal',
        'is_main': true,
      }),
      PurchaseWarehouse.fromMap({'id': 'wh-2', 'name': 'Bodega 2'}),
    ],
    inventoryItems: const [],
    orders: const [],
  );

  @override
  Future<void> init({bool force = false}) async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<PurchaseOrderDetail> loadOrderDetail(String orderId) async => _detail;

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
  }) async {
    updateCalls += 1;
    sentItems = items;
    sentSupplierId = supplierId;
    sentWarehouseId = warehouseId;
    sentInvoiceNumber = invoiceNumber;
    sentNcf = ncf;
    sentReason = reason;
    sentDiscount = discount;
    return const PurchaseOrderUpdateResult(
      orderId: 'po-1',
      status: 'received',
      total: 12760.8,
      movementsCreated: 2,
      payableAdjusted: false,
      replayed: false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeSessionController extends SessionController {
  _FakeSessionController(this._permissions);
  final Set<String> _permissions;

  @override
  SessionState build() => SessionState(permissions: _permissions);
}

/// Compra RECIBIDA con dos líneas: una comprada por caja (empaque) y una
/// exenta sin insumo vinculado. Es el caso que más fácil se desconfigura al
/// reabrirlo.
PurchaseOrderDetail _detail({String status = 'received'}) {
  return PurchaseOrderDetail(
    order: PurchaseOrderSummary.fromMap(
      {
        'id': 'po-1',
        'supplier_id': 'sup-1',
        'warehouse_id': 'wh-1',
        'order_number': 'PO-00002',
        'invoice_number': 'P0344202',
        'ncf': 'B0100000284',
        'status': status,
        'total': 12760.8,
        'notes': 'Entrega completa',
        'created_at': '2026-08-27T14:08:00Z',
        'expected_date': '2026-08-29',
      },
      supplierName: 'Bepensa',
      warehouseName: 'Almacen Principal',
    ),
    subtotal: 10800 + 2596.8,
    tax: 1944,
    discount: 0,
    lines: [
      PurchaseOrderLine.fromMap({
        'id': 'poi-1',
        'inventory_item_id': 'item-1',
        'description': 'Coca-Cola 12 oz',
        'quantity_ordered': 240,
        'quantity_received': 240,
        'unit_cost': 45,
        'tax_rate': 18,
        'total': 10800,
        'purchase_unit': 'caja',
        'pack_size': 24,
        'inventory_items': {
          'name': 'Coca-Cola 12 oz',
          'unit': 'unidad',
          'sku': 'COCA-12',
        },
      }),
      PurchaseOrderLine.fromMap({
        'id': 'poi-2',
        'description': 'Transporte',
        'quantity_ordered': 1,
        'quantity_received': 1,
        'unit_cost': 2596.8,
        'tax_rate': 0,
        'total': 2596.8,
      }),
    ],
  );
}

Future<_FakePurchasesViewModel> _pump(
  WidgetTester tester, {
  PurchaseOrderDetail? detail,
  Set<String> permissions = const {
    'compras.acceso',
    'compras.ordenes.editar',
  },
}) async {
  tester.view.physicalSize = const Size(1500, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final vm = _FakePurchasesViewModel(detail ?? _detail());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchasesViewModelProvider.overrideWith((ref) => vm),
        sessionProvider.overrideWith(
          () => _FakeSessionController(permissions),
        ),
        businessFeaturesProvider.overrideWith(
          (ref) async => BusinessFeatures.defaults,
        ),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/edit',
          routes: [
            GoRoute(
              path: '/edit',
              builder: (_, _) =>
                  const PurchasesRegisterView(editOrderId: 'po-1'),
            ),
            // Destino tras guardar: el detalle de la compra corregida.
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

/// Busca el TextField cuyo label coincide. El label se pinta DENTRO del
/// TextField (TextField → InputDecorator → Text), así que se sube al
/// TextField que lo contiene.
TextField _fieldByLabel(WidgetTester tester, String label) {
  return tester.widget<TextField>(
    find
        .ancestor(of: find.text(label), matching: find.byType(TextField))
        .first,
  );
}

void main() {
  testWidgets('reabre la compra con sus datos de cabecera', (tester) async {
    await _pump(tester);

    expect(find.text('Editar compra'), findsOneWidget);
    expect(
      find.text('PO-00002 · Factura P0344202 · Recibida'),
      findsOneWidget,
    );
    expect(_fieldByLabel(tester, 'Número de orden').controller?.text,
        'PO-00002');
    expect(_fieldByLabel(tester, 'Número de factura *').controller?.text,
        'P0344202');
    expect(_fieldByLabel(tester, 'NCF (opcional)').controller?.text,
        'B0100000284');
  });

  testWidgets('el número de orden no se puede cambiar al corregir',
      (tester) async {
    await _pump(tester);
    expect(_fieldByLabel(tester, 'Número de orden').readOnly, isTrue);
  });

  testWidgets('no ofrece el selector de estado: lo recalcula el servidor',
      (tester) async {
    await _pump(tester);
    expect(find.text('Estado'), findsNothing);
  });

  testWidgets('avisa que la compra ya metió mercancía al almacén',
      (tester) async {
    await _pump(tester);
    expect(
      find.textContaining('ya metió 241 unidades a Almacen Principal'),
      findsOneWidget,
    );
    expect(find.text('Guardar y ajustar inventario'), findsOneWidget);
  });

  testWidgets('una compra sin mercancía recibida no avisa de inventario',
      (tester) async {
    final pending = PurchaseOrderDetail(
      order: _detail(status: 'sent').order,
      subtotal: 100,
      tax: 18,
      discount: 0,
      lines: [
        PurchaseOrderLine.fromMap({
          'id': 'poi-9',
          'inventory_item_id': 'item-9',
          'description': 'Ron',
          'quantity_ordered': 2,
          'quantity_received': 0,
          'unit_cost': 50,
          'tax_rate': 18,
          'total': 100,
        }),
      ],
    );
    await _pump(tester, detail: pending);

    expect(find.textContaining('ya metió'), findsNothing);
    expect(find.text('Guardar cambios'), findsOneWidget);
  });

  testWidgets('sin el permiso no dibuja el formulario', (tester) async {
    await _pump(tester, permissions: const {'compras.acceso'});

    expect(
      find.text('No tienes permiso para editar compras registradas'),
      findsOneWidget,
    );
    expect(find.text('Editar compra'), findsNothing);
  });

  testWidgets('guardar sin tocar nada devuelve las mismas líneas',
      (tester) async {
    final vm = await _pump(tester);

    await tester.tap(find.text('Guardar y ajustar inventario'));
    await tester.pumpAndSettle();
    // Corrección sobre mercancía ya recibida: confirma primero.
    expect(find.text('Esta corrección mueve inventario'), findsOneWidget);
    await tester.tap(find.text('Corregir'));
    await tester.pumpAndSettle();

    final items = vm.sentItems!;
    expect(vm.updateCalls, 1);
    expect(items, hasLength(2));

    // Línea con empaque: vuelve en unidad BASE, con el mismo costo neto.
    expect(items[0].id, 'poi-1');
    expect(items[0].inventoryItemId, 'item-1');
    expect(items[0].quantity, closeTo(240, 0.0001));
    expect(items[0].unitCost, closeTo(45, 0.0001));
    expect(items[0].total, closeTo(10800, 0.01));
    expect(items[0].taxValue, closeTo(1944, 0.01));
    expect(items[0].purchaseUnit, 'caja');
    expect(items[0].packSize, 24);

    // Línea exenta y sin insumo: sigue sin ITBIS.
    expect(items[1].id, 'poi-2');
    expect(items[1].inventoryItemId, isNull);
    expect(items[1].quantity, closeTo(1, 0.0001));
    expect(items[1].unitCost, closeTo(2596.8, 0.0001));
    expect(items[1].taxValue, closeTo(0, 0.0001));

    // Y la cabecera vuelve igual.
    expect(vm.sentSupplierId, 'sup-1');
    expect(vm.sentWarehouseId, 'wh-1');
    expect(vm.sentInvoiceNumber, 'P0344202');
    expect(vm.sentNcf, 'B0100000284');
    expect(vm.sentDiscount, 0);
  });

  testWidgets('el motivo de la corrección viaja al servidor', (tester) async {
    final vm = await _pump(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Ej. se digitó 12 y llegaron 10'),
      'se contaron 10 cajas, no 12',
    );
    await tester.tap(find.text('Guardar y ajustar inventario'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Corregir'));
    await tester.pumpAndSettle();

    expect(vm.sentReason, 'se contaron 10 cajas, no 12');
  });

  testWidgets('cancelar la confirmación no guarda nada', (tester) async {
    final vm = await _pump(tester);

    await tester.tap(find.text('Guardar y ajustar inventario'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(vm.updateCalls, 0);
  });

  testWidgets('una factura vieja abre su selector de fecha sin reventar',
      (tester) async {
    // Compra de hace más de 90 días: el rango por defecto del selector no la
    // alcanza y `initialDate` quedaría fuera.
    final old = _detail();
    final vieja = PurchaseOrderDetail(
      order: PurchaseOrderSummary.fromMap(
        {
          'id': 'po-1',
          'supplier_id': 'sup-1',
          'warehouse_id': 'wh-1',
          'order_number': 'PO-00002',
          'invoice_number': 'P0344202',
          'status': 'received',
          'total': 12760.8,
          'created_at': '2025-01-10T14:08:00Z',
          'expected_date': '2025-01-12',
        },
        supplierName: 'Bepensa',
        warehouseName: 'Almacen Principal',
      ),
      subtotal: old.subtotal,
      tax: old.tax,
      discount: 0,
      lines: old.lines,
    );
    await _pump(tester, detail: vieja);

    await tester.tap(find.text('12/01/2025'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(DatePickerDialog), findsOneWidget);
  });

  testWidgets('una línea en cero no se cae en silencio', (tester) async {
    final vm = await _pump(tester);

    // La cantidad de la primera línea (10 cajas) se pone en cero.
    await tester.enterText(find.widgetWithText(TextField, '10').first, '0');
    await tester.tap(find.text('Guardar y ajustar inventario'));
    await tester.pumpAndSettle();

    expect(vm.updateCalls, 0);
    expect(find.textContaining('sin cantidad o sin producto'), findsOneWidget);
  });

  testWidgets('no deja guardar una compra sin número de factura',
      (tester) async {
    final vm = await _pump(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Ej. 0004521'),
      '   ',
    );
    await tester.tap(find.text('Guardar y ajustar inventario'));
    await tester.pumpAndSettle();

    expect(vm.updateCalls, 0);
    expect(
      find.textContaining('número de factura'),
      findsWidgets,
    );
  });
}
