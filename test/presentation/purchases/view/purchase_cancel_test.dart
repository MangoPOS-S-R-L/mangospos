// Anular una compra registrada, desde el detalle de la factura.
//
// Lo que importa acá: el botón solo aparece con el permiso y en una compra
// viva; nadie confirma sin ver la vista previa ni sin escribir el motivo; una
// cuenta por pagar con abonos bloquea; y un reintento tras un error de red
// manda la MISMA llave (el servidor la reconoce y no anula dos veces).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/purchases/state/purchases_state.dart';
import 'package:mangopos/presentation/purchases/view/purchase_cancel_dialog.dart';
import 'package:mangopos/presentation/purchases/view/purchase_order_detail_view.dart';
import 'package:mangopos/presentation/purchases/viewmodel/purchases_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

class _FakePurchasesViewModel extends ChangeNotifier
    implements PurchasesViewModel {
  _FakePurchasesViewModel(this.detail, this.preview);

  PurchaseOrderDetail detail;
  final PurchaseOrderCancelPreview preview;

  final List<({String reason, String key})> cancelCalls = [];
  int failuresLeft = 0;

  @override
  Future<PurchaseOrderDetail> loadOrderDetail(String orderId) async => detail;

  @override
  Future<PurchaseOrderCancelPreview> previewCancelPurchaseOrder(
    String orderId,
  ) async => preview;

  @override
  Future<PurchaseOrderCancelResult> cancelPurchaseOrder({
    required String orderId,
    required String reason,
    required String idempotencyKey,
  }) async {
    cancelCalls.add((reason: reason, key: idempotencyKey));
    if (failuresLeft > 0) {
      failuresLeft -= 1;
      throw Exception('Sin conexión con el servidor');
    }
    detail = _detail(status: 'cancelled', reason: reason);
    return PurchaseOrderCancelResult.fromMap({
      'movements_created': preview.lines.length,
      'costs_restored': 1,
      'receptions_cancelled': preview.receptionsToCancel,
      'payable_cancelled': preview.hasPayable,
      'negative_items': preview.negativeItems,
      'replayed': false,
    });
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

PurchaseOrderDetail _detail({String status = 'received', String? reason}) {
  return PurchaseOrderDetail(
    order: PurchaseOrderSummary.fromMap(
      {
        'id': 'po-1',
        'order_number': 'PO-00077',
        'invoice_number': 'F-9',
        'status': status,
        'total': 7080,
        'created_at': '2026-09-20T14:08:00Z',
      },
      supplierName: 'Peralta',
      warehouseName: 'Almacen Principal',
    ),
    subtotal: 6000,
    tax: 1080,
    discount: 0,
    lines: [
      PurchaseOrderLine.fromMap({
        'id': 'poi-1',
        'inventory_item_id': 'item-1',
        'description': 'Ron Barcelo',
        'quantity_ordered': 12,
        'quantity_received': 12,
        'unit_cost': 500,
        'tax_rate': 18,
        'total': 6000,
        'inventory_items': {'name': 'Ron Barcelo', 'unit': 'botella'},
      }),
    ],
    cancelledAt: reason == null ? null : DateTime(2026, 9, 29, 10),
    cancelledByName: reason == null ? '' : 'Ana Pérez',
    cancelReason: reason ?? '',
  );
}

PurchaseOrderCancelPreview _preview({
  bool blocked = false,
  bool negative = false,
}) {
  return PurchaseOrderCancelPreview.fromMap({
    'status': 'received',
    'preview': true,
    'lines': [
      {
        'item_name': 'Ron Barcelo',
        'warehouse_name': 'Almacen Principal',
        'unit': 'botella',
        'quantity': 12,
        'stock_before': negative ? 2 : 20,
        'stock_after': negative ? -10 : 8,
      },
    ],
    'negative_items': negative ? 1 : 0,
    'receptions_to_cancel': 1,
    'has_payable': true,
    'payable_amount': 7080,
    'payable_paid': blocked ? 1000 : 0,
    'blocked_reason': blocked ? 'PURCHASE_ORDER_PAYABLE_HAS_PAYMENTS' : null,
  });
}

Future<_FakePurchasesViewModel> _pump(
  WidgetTester tester, {
  Set<String> perms = const {'compras.acceso', 'compras.ordenes.anular'},
  String status = 'received',
  String? reason,
  PurchaseOrderCancelPreview? preview,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final vm = _FakePurchasesViewModel(
    _detail(status: status, reason: reason),
    preview ?? _preview(),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchasesViewModelProvider.overrideWith((ref) => vm),
        sessionProvider.overrideWith(() => _Session(perms)),
      ],
      child: const MaterialApp(
        home: PurchaseOrderDetailView(orderId: 'po-1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return vm;
}

final _confirm = find.byKey(const Key('purchase-cancel-confirm'));

bool _enabled(WidgetTester tester) =>
    tester.widget<ButtonStyleButton>(_confirm).onPressed != null;

void main() {
  testWidgets('sin el permiso no aparece el botón', (tester) async {
    await _pump(tester, perms: const {'compras.acceso'});
    expect(find.byKey(const Key('purchase-cancel-button')), findsNothing);
  });

  testWidgets('una compra ya anulada no ofrece anular y dice quién y por qué',
      (tester) async {
    await _pump(tester, status: 'cancelled', reason: 'Factura duplicada.');
    expect(find.byKey(const Key('purchase-cancel-button')), findsNothing);
    expect(
      find.textContaining('Compra anulada el 29/09/2026 por Ana Pérez'),
      findsOneWidget,
    );
    // El punto final del motivo no se duplica.
    expect(find.textContaining('Motivo: Factura duplicada.'), findsOneWidget);
    expect(find.textContaining('duplicada..'), findsNothing);
  });

  testWidgets('muestra la vista previa y exige motivo antes de confirmar', (
    tester,
  ) async {
    final vm = await _pump(tester, preview: _preview(negative: true));

    await tester.tap(find.byKey(const Key('purchase-cancel-button')));
    await tester.pumpAndSettle();

    expect(find.text('Anular compra PO-00077'), findsOneWidget);
    expect(find.text('−12 botella'), findsOneWidget);
    expect(
      find.text('Almacen Principal · existencia 2 → -10 botella'),
      findsOneWidget,
    );
    expect(find.textContaining('Un insumo quedará en negativo'), findsOneWidget);
    expect(find.text('Se anula 1 conduce de recepción.'), findsOneWidget);
    expect(find.textContaining('se cancela'), findsOneWidget);

    // Sin motivo no se puede.
    expect(_enabled(tester), isFalse);

    // Un motivo frecuente llena el campo.
    await tester.tap(find.text('Factura registrada dos veces'));
    await tester.pump();
    expect(_enabled(tester), isTrue);

    await tester.tap(_confirm);
    await tester.pumpAndSettle();

    expect(vm.cancelCalls, hasLength(1));
    expect(vm.cancelCalls.single.reason, 'Factura registrada dos veces');
    // El detalle se recarga ya anulado.
    expect(find.byKey(const Key('purchase-cancel-button')), findsNothing);
    expect(find.textContaining('Compra anulada'), findsWidgets);
  });

  testWidgets('con abonos en la CxP está bloqueado y no pide motivo', (
    tester,
  ) async {
    final vm = await _pump(tester, preview: _preview(blocked: true));

    await tester.tap(find.byKey(const Key('purchase-cancel-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('ya tiene abonos'), findsOneWidget);
    expect(find.byKey(const Key('purchase-cancel-reason')), findsNothing);
    expect(_enabled(tester), isFalse);
    expect(vm.cancelCalls, isEmpty);
  });

  testWidgets('un reintento tras un error manda la MISMA llave', (
    tester,
  ) async {
    final vm = await _pump(tester);
    vm.failuresLeft = 1;

    await tester.tap(find.byKey(const Key('purchase-cancel-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('purchase-cancel-reason')),
      'Registrada por error',
    );
    await tester.pump();

    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    // Falló: el diálogo sigue abierto con el error y se puede reintentar.
    expect(find.textContaining('Sin conexión'), findsOneWidget);
    expect(_enabled(tester), isTrue);

    await tester.tap(_confirm);
    await tester.pumpAndSettle();

    expect(vm.cancelCalls, hasLength(2));
    expect(vm.cancelCalls[0].key, vm.cancelCalls[1].key);
    expect(find.text('Anular compra PO-00077'), findsNothing);
  });

  test('formatCancelQty quita los ceros de relleno', () {
    expect(formatCancelQty(12), '12');
    expect(formatCancelQty(10), '10');
    expect(formatCancelQty(1.5), '1.5');
    expect(formatCancelQty(-10), '-10');
    expect(formatCancelQty(0.125), '0.13');
  });

  test('la vista previa reconoce una orden que otro ya anuló', () {
    final p = PurchaseOrderCancelPreview.fromMap({
      'status': 'cancelled',
      'replayed': true,
      'lines': [],
    });
    expect(p.alreadyCancelled, isTrue);
    expect(p.blocked, isFalse);
  });
}
