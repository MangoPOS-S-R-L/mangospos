// Smoke test de la pantalla de detalle de una factura de compra: que arme sus
// tres bloques (cabecera, productos y desglose) sin overflow, tanto en la
// laptop del negocio como en una ventana angosta.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/purchases/state/purchases_state.dart';
import 'package:mangopos/presentation/purchases/view/purchase_order_detail_view.dart';
import 'package:mangopos/presentation/purchases/viewmodel/purchases_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// ViewModel de mentira: la pantalla solo le pide el detalle, así el test no
/// necesita Supabase.
class _FakePurchasesViewModel extends ChangeNotifier
    implements PurchasesViewModel {
  _FakePurchasesViewModel(this._detail);

  final PurchaseOrderDetail _detail;

  @override
  Future<PurchaseOrderDetail> loadOrderDetail(String orderId) async => _detail;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Sesión de mentira: `SessionController.build()` toca Supabase.
class _FakeSessionController extends SessionController {
  @override
  SessionState build() => const SessionState(
    permissions: {'compras.acceso', 'compras.ordenes.recibir'},
  );
}

PurchaseOrderDetail _detail({
  String status = 'partial',
  double orderDiscount = 0,
  double total = 15340,
}) {
  final lines = [
    // Línea con empaque: se compró por caja, el stock vive en unidades.
    PurchaseOrderLine.fromMap({
      'id': 'poi-1',
      'inventory_item_id': 'item-1',
      'description': 'Coca-Cola 12 oz',
      'quantity_ordered': 240,
      'quantity_received': 120,
      'unit_cost': 45,
      'tax_rate': 18,
      'total': 10800,
      'discount': 400,
      'purchase_unit': 'caja',
      'pack_size': 24,
      'inventory_items': {
        'name': 'Coca-Cola 12 oz',
        'unit': 'unidad',
        'sku': 'COCA-12',
        'tracks_lots': false,
      },
    }),
    // Línea exenta y sin insumo vinculado (no mueve inventario).
    PurchaseOrderLine.fromMap({
      'id': 'poi-2',
      'description': 'Transporte',
      'quantity_ordered': 1,
      'quantity_received': 1,
      'unit_cost': 2596.8,
      'tax_rate': 0,
      'total': 2596.8,
    }),
  ];

  return PurchaseOrderDetail(
    order: PurchaseOrderSummary.fromMap(
      {
        'id': 'po-1',
        'order_number': 'PO-00002',
        'invoice_number': 'P0344202',
        'ncf': 'B0100000284',
        'status': status,
        'total': total,
        'notes': 'Entrega parcial $kPendingPayableTag',
        'created_at': '2026-08-27T14:08:00Z',
        'expected_date': '2026-08-29',
      },
      supplierName: 'Bepensa Dominicana',
      warehouseName: 'Almacen Principal',
    ),
    subtotal: 13396.8,
    tax: 1944,
    discount: orderDiscount,
    lines: lines,
  );
}

Future<void> _pump(WidgetTester tester, {required Size size}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchasesViewModelProvider.overrideWith(
          (ref) => _FakePurchasesViewModel(_detail()),
        ),
        sessionProvider.overrideWith(_FakeSessionController.new),
      ],
      child: const MaterialApp(
        home: PurchaseOrderDetailView(orderId: 'po-1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('muestra cabecera, productos y desglose en pantalla ancha', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1400, 1000));

    expect(find.text('PO-00002'), findsOneWidget);
    expect(
      find.text('Bepensa Dominicana · Factura P0344202 · NCF B0100000284'),
      findsOneWidget,
    );
    expect(find.text('Productos comprados'), findsOneWidget);
    expect(find.text('Coca-Cola 12 oz'), findsOneWidget);
    expect(find.text('Transporte'), findsOneWidget);
    expect(find.text('Desglose de la factura'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
  });

  testWidgets('la compra por caja se muestra en cajas con su equivalencia', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1400, 1000));

    // 240 unidades / 24 por caja = 10 cajas, a RD$45 × 24 = RD$1,080 la caja.
    expect(find.text('10 caja'), findsOneWidget);
    expect(find.text('240 unidad'), findsOneWidget);
    expect(find.text(r'RD$1,080.00'), findsOneWidget);
    expect(find.text(r'RD$45.00 / unidad'), findsOneWidget);
  });

  testWidgets('avisa lo que falta por recibir y la CxP sin registrar', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1400, 1000));

    expect(find.text('Recibido 5 de 10'), findsOneWidget);
    expect(find.textContaining('cuenta por pagar no llegó a crearse'),
        findsOneWidget);
    expect(find.text('Recibir resto'), findsOneWidget);
  });

  testWidgets('en ventana angosta las líneas se apilan sin overflow', (
    tester,
  ) async {
    await _pump(tester, size: const Size(700, 1100));

    expect(find.text('Coca-Cola 12 oz'), findsOneWidget);
    expect(find.text('Desglose de la factura'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
