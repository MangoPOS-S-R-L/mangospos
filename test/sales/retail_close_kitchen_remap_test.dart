// V1: cerrar la pestaña de una venta retail ya cobrada solo la retira; nunca
// la anula (fn_close_order_and_table pasaría la venta cobrada a 'void').
// V2: si la orden local se sube y se remapea mientras se imprime la comanda
// por la LAN, la ronda queda enviada en la pantalla actual y un segundo
// «Enviar» no la reimprime.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/business/business_model.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:mangopos/data/models/fiscal_models.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/by_zone_state.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/retail_carts_provider.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/fiscal/fiscal_service.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Session extends SessionController {
  _Session(this.businessId);
  final String businessId;
  @override
  SessionState build() => SessionState(
    activeBusinessId: businessId,
    activeBusinessName: 'Tienda',
    userName: 'Cajero',
    permissions: {'ventas.orden.agregar_item', 'ventas.orden.enviar_cocina'},
  );
}

class _Sales extends SalesViewModel {
  _Sales(this.initial);
  final CurrentOrderState initial;
  @override
  CurrentOrderState build() => initial;
  @override
  Future<bool> ensureCashSessionOpen() async => true;
  @override
  Future<void> refreshOrder({bool clearIfPaid = false}) async {}
  void showForTest(CurrentOrderState selected) => state = selected;
}

class _CloudHub extends StateNotifier<TerminalMode>
    implements HubModeController {
  _CloudHub() : super(TerminalMode.cloud);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Zones extends ByZoneViewModel {
  @override
  ByZoneState build() => const ByZoneState();
}

class _Fiscal implements FiscalService {
  @override
  Future<List<FiscalNcfSequence>> getSequences(String businessId) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _Bundle = ({
  Order? order,
  List<OrderItem> items,
  List<OrderCheck> checks,
  String? customerId,
  String? customerName,
  String? note,
});

class _Repository extends SalesRepository {
  _Repository(super.client);
  final bundles = <String, _Bundle>{};
  final closed = <(String, String)>[];

  @override
  Future<_Bundle> getOrderBundle(String orderId, {String? businessId}) async {
    final bundle = bundles[orderId];
    if (bundle != null) return bundle;
    throw TimeoutException('bundle sin respuesta');
  }

  @override
  Future<void> closeOrder({
    required String orderId,
    required String status,
  }) async {
    closed.add((orderId, status));
  }

  /// Servidor sin 20261009_0007: se usa el cierre de siempre.
  @override
  Future<String> voidOrderIfUnpaid(String orderId) async =>
      throw const PostgrestException(
        message: 'Could not find the function public.fn_void_order_if_unpaid',
        code: 'PGRST202',
      );
}

class _DelayedKitchen extends PrintingService {
  _DelayedKitchen(super.client);
  final started = Completer<void>();
  final release = Completer<void>();
  int localSends = 0;
  final onlineExcluded = <Set<String>>[];

  @override
  Future<LocalKitchenSendResult> sendLocalOrderToKitchen({
    required String businessId,
    required CurrentOrderState localState,
    String tableName = 'LOCAL',
    String? waiterName,
    String? businessName,
    KitchenAreaPrinterChooser? choosePrinter,
    bool forceChoosePrinter = false,
  }) async {
    localSends++;
    started.complete();
    await release.future;
    return const LocalKitchenSendResult(dispatchIds: {}, pendingAreas: []);
  }

  @override
  Future<KitchenSendResult> sendOrderToKitchen({
    required String orderId,
    required String businessId,
    String? fallbackTableName,
    String? fallbackWaiterName,
    Set<String> excludeItemIds = const {},
    Set<String> excludeAreaCodes = const {},
    bool allowKitchenMerge = true,
    KitchenAreaPrinterChooser? choosePrinter,
    bool forceChoosePrinter = false,
  }) async {
    onlineExcluded.add(excludeItemIds);
    return const KitchenSendResult(
      dispatchIds: {},
      directAreas: [],
      escalatedAreas: [],
    );
  }
}

Order _order(String id, {String status = 'open', String? closedAt}) =>
    Order.fromMap({
      'id': id,
      'session_id': 'session-$id',
      'status_ext': status,
      'subtotal': 100,
      'total': 100,
      'created_at': '2026-10-09T12:00:00Z',
      'closed_at': closedAt,
    });

OrderItem _item(String id, String orderId, {String status = 'draft'}) =>
    OrderItem.fromMap({
      'id': id,
      'order_id': orderId,
      'product_name': 'Producto $id',
      'product_id': 'product-$id',
      'qty': 1,
      'unit_price': 100,
      'subtotal': 100,
      'total': 100,
      'status': status,
      'created_at': '2026-10-09T12:00:00Z',
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final offline = OfflinePosService();
  final keys = <String, String>{};
  late OfflineQueueDb db;
  late SupabaseClient client;

  http.Response empty(http.BaseRequest request) => http.Response(
    request.method == 'GET' ? '[]' : 'null',
    200,
    headers: {'content-type': 'application/json'},
    request: request as http.Request,
  );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            if (call.method == 'write') {
              keys[args['key'] as String] = args['value'] as String;
            }
            if (call.method == 'read') return keys[args['key']];
            if (call.method == 'containsKey') {
              return keys.containsKey(args['key']);
            }
            return null;
          },
        );
    db = OfflineQueueDb.inMemory(NativeDatabase.memory());
    OfflineQueueDb.debugInstance = db;
    client = SupabaseClient(
      'http://localhost:54321',
      'test',
      httpClient: MockClient((request) async => empty(request)),
    );
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient((request) async => empty(request)),
    );
  });

  setUp(() {
    offline.setHubUploader(null);
    ConnectivityService().simulateReconnect();
  });

  tearDownAll(() async {
    await db.close();
    await client.dispose();
    await Supabase.instance.dispose();
  });

  ProviderContainer container(
    String biz,
    CurrentOrderState initial, {
    _Repository? repository,
    PrintingService? printing,
    bool retail = false,
  }) {
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(() => _Sales(initial)),
        currentBusinessModelProvider.overrideWithValue(
          retail ? BusinessModel.retail : BusinessModel.restaurant,
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        byZoneVmProvider.overrideWith(_Zones.new),
        fiscalServiceProvider.overrideWithValue(_Fiscal()),
        salesRepositoryProvider.overrideWithValue(
          repository ?? _Repository(client),
        ),
        printingServiceProvider.overrideWithValue(
          printing ?? PrintingService(client),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  for (final activeTab in [false, true]) {
    test('cerrar la pestaña restaurada de una venta ya cobrada no la anula '
        '(${activeTab ? 'activa' : 'inactiva'})', () async {
      final biz = 'retail-paid-tab-$activeTab';
      const paidId = 'order-paid';
      // Respaldo previo al cobro (la app murió antes de retirar la pestaña).
      await offline.saveSnapshot(
        businessId: biz,
        slotId: 'quick-A',
        origin: 'quick',
        state: CurrentOrderState(
          origin: 'quick',
          order: _order(paidId),
          items: [
            _item('a1', paidId),
            _item('a2', paidId),
            _item('a3', paidId),
          ],
        ),
      );
      await offline.saveSnapshot(
        businessId: biz,
        slotId: 'quick-B',
        origin: 'quick',
        state: CurrentOrderState(
          origin: 'quick',
          order: _order('local-order-b'),
          items: [_item('tmp_b', 'local-order-b')],
        ),
      );
      await offline.saveRetailCartsIndex(
        businessId: biz,
        carts: [
          const RetailCart(slotId: 'quick-A', number: 1, orderId: paidId),
          const RetailCart(
            slotId: 'quick-B',
            number: 2,
            orderId: 'local-order-b',
          ),
        ].map((cart) => cart.toMap()).toList(),
        activeSlotId: activeTab ? 'quick-A' : 'quick-B',
      );
      final repository = _Repository(client)
        ..bundles[paidId] = (
          order: _order(
            paidId,
            status: 'paid',
            closedAt: '2026-10-09T12:30:00Z',
          ),
          items: const <OrderItem>[],
          checks: const <OrderCheck>[],
          customerId: null,
          customerName: null,
          note: null,
        );
      final c = container(
        biz,
        const CurrentOrderState(),
        repository: repository,
        retail: true,
      );
      final vm = c.read(currentOrderProvider.notifier);
      expect(await vm.restoreRetailCarts(), isTrue);
      if (activeTab) {
        expect(c.read(currentOrderProvider).order?.status, 'paid');
      }

      await vm.closeRetailCart('quick-A');

      expect(repository.closed, isEmpty);
      expect(c.read(retailCartsProvider).carts.map((cart) => cart.slotId), [
        'quick-B',
      ]);
      expect(c.read(currentOrderProvider).order?.id, 'local-order-b');
      expect(
        await offline.isOrderClosedLocally(businessId: biz, orderId: paidId),
        isTrue,
      );
      final queued = await offline.unsettledActions(biz);
      expect(queued.map((a) => a['type']), isNot(contains('void_order')));
    });
  }

  test('cerrar la pestaña de una venta abierta sigue anulándola', () async {
    const biz = 'retail-open-tab';
    const openId = 'order-open';
    await offline.saveRetailCartsIndex(
      businessId: biz,
      carts: [
        const RetailCart(slotId: 'quick-A', number: 1, orderId: openId),
        const RetailCart(slotId: 'quick-B', number: 2),
      ].map((cart) => cart.toMap()).toList(),
      activeSlotId: 'quick-A',
    );
    final repository = _Repository(client)
      ..bundles[openId] = (
        order: _order(openId),
        items: [_item('o1', openId)],
        checks: const <OrderCheck>[],
        customerId: null,
        customerName: null,
        note: null,
      );
    final c = container(
      biz,
      const CurrentOrderState(),
      repository: repository,
      retail: true,
    );
    final vm = c.read(currentOrderProvider.notifier);
    expect(await vm.restoreRetailCarts(), isTrue);
    expect(c.read(currentOrderProvider).order?.id, openId);

    await vm.closeRetailCart('quick-A');

    expect(repository.closed, [(openId, 'void')]);
    expect(c.read(retailCartsProvider).carts.map((cart) => cart.slotId), [
      'quick-B',
    ]);
  });

  test('orden subida y remapeada durante la impresión local: la ronda queda '
      'enviada y un segundo «Enviar» no la reimprime', () async {
    const biz = 'kitchen-remap-during-print';
    final printing = _DelayedKitchen(client);
    final c = container(
      biz,
      CurrentOrderState(
        origin: 'table',
        order: _order('local-order-X'),
        items: [_item('tmp_1', 'local-order-X')],
      ),
      printing: printing,
    );
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    final vm = c.read(currentOrderProvider.notifier) as _Sales;

    final sending = vm.confirmOrder();
    await printing.started.future;
    // La sync sube la orden mientras sale el papel y la recarga con su UUID.
    final storage = await StorageService.getInstance();
    await storage.writeJson('offline_order_map_$biz', {
      'local-order-X': 'remote-X',
    });
    await storage.writeJson('offline_item_map_$biz', {
      'tmp_1': 'remote-item',
    });
    vm.showForTest(
      CurrentOrderState(
        origin: 'table',
        order: _order('remote-X'),
        items: [_item('remote-item', 'remote-X')],
      ),
    );
    printing.release.complete();
    await sending;

    final after = c.read(currentOrderProvider);
    expect(after.order?.id, 'remote-X');
    expect(after.items.single.id, 'remote-item');
    expect(after.items.single.status, 'pending');

    await vm.confirmOrder();
    expect(printing.localSends, 1);
    final excluded = printing.onlineExcluded.single;
    expect(
      c
          .read(currentOrderProvider)
          .items
          .where((item) => !excluded.contains(item.id)),
      isEmpty,
    );
  });
}
