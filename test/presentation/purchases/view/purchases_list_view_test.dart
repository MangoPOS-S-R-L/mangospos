// El listado de Compras tiene que dejar entrar a cada factura y tener salida
// hacia atrás. Este test cubre las dos cosas —y que la cabecera no reviente
// en la tablet de 1024×600, donde ahora convive el botón de volver con los
// de "Nuevo proveedor" y "Nueva orden".

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/presentation/purchases/state/purchases_state.dart';
import 'package:mangopos/presentation/purchases/view/purchases_list_view.dart';
import 'package:mangopos/presentation/purchases/viewmodel/purchases_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

class _FakePurchasesViewModel extends ChangeNotifier
    implements PurchasesViewModel {
  _FakePurchasesViewModel(this._state);

  final PurchasesState _state;

  @override
  PurchasesState get state => _state;

  @override
  Future<void> init({bool force = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeSessionController extends SessionController {
  @override
  SessionState build() => const SessionState(
    permissions: {
      'compras.acceso',
      'compras.ordenes.crear',
      'compras.ordenes.recibir',
      'compras.proveedores.crear_editar',
    },
  );
}

PurchasesState _state() {
  PurchaseOrderSummary order(String number, String id, String status) {
    return PurchaseOrderSummary.fromMap(
      {
        'id': id,
        'order_number': number,
        'invoice_number': 'P0344202',
        'status': status,
        'total': 8480,
        'created_at': '2026-08-27T14:08:00Z',
        'expected_date': '2026-08-29',
      },
      supplierName: 'Bepensa Dominicana',
      warehouseName: 'Almacen Principal',
    );
  }

  return PurchasesState(
    orders: [
      order('PO-00002', 'po-2', 'received'),
      order('PO-00001', 'po-1', 'partial'),
    ],
    suppliers: const [
      PurchaseSupplier(
        id: 'sup-1',
        name: 'Bepensa Dominicana',
        contactName: '',
        phone: '',
        email: '',
        isActive: true,
      ),
    ],
  );
}

String? _lastRoute;

Future<void> _pump(WidgetTester tester, {required Size size}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  _lastRoute = null;

  final router = GoRouter(
    initialLocation: AppRoutes.purchasesList,
    routes: [
      GoRoute(
        path: AppRoutes.purchasesList,
        builder: (_, _) => const PurchasesListView(),
      ),
      GoRoute(
        path: AppRoutes.purchasesOrderDetail,
        builder: (_, state) {
          _lastRoute = state.uri.path;
          return const Scaffold(body: Text('detalle'));
        },
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (_, _) {
          _lastRoute = AppRoutes.settings;
          return const Scaffold(body: Text('ajustes'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchasesViewModelProvider.overrideWith(
          (ref) => _FakePurchasesViewModel(_state()),
        ),
        sessionProvider.overrideWith(_FakeSessionController.new),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tocar una orden abre su factura', (tester) async {
    await _pump(tester, size: const Size(1400, 1000));

    await tester.tap(find.textContaining('PO-00002'));
    await tester.pumpAndSettle();

    expect(_lastRoute, '/settings/purchases/order/po-2');
    expect(find.text('detalle'), findsOneWidget);
  });

  testWidgets('el botón de atrás vuelve a Ajustes', (tester) async {
    await _pump(tester, size: const Size(1400, 1000));

    await tester.tap(find.byTooltip('Volver a Ajustes'));
    await tester.pumpAndSettle();

    expect(_lastRoute, AppRoutes.settings);
  });

  testWidgets('la cabecera cabe en la tablet de 1024×600', (tester) async {
    await _pump(tester, size: const Size(1024, 600));

    expect(find.text('Compras'), findsOneWidget);
    expect(find.byTooltip('Volver a Ajustes'), findsOneWidget);
    expect(find.text('Nueva orden'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
