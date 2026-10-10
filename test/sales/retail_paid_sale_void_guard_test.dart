// Una venta retail cobrada nunca se anula al cerrar su pestaña, aunque la
// pantalla siga diciendo «abierta» (falló la recarga posterior al cobro, o se
// repintó el respaldo previo al cobro):
// - En línea, closeRetailCart lee el servidor antes de anular; si dice
//   cobrada, solo retira la pestaña.
// - Si la lectura falla, o no hay red, NO anula en línea: encola el void, y su
//   replay vuelve a leer el servidor y omite la venta cobrada.
// - La anulación explícita de una venta cobrada (annulOrder, con motivo) sigue
//   funcionando igual.

import 'dart:async';
import 'dart:convert';

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
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/fiscal_models.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
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
    permissions: {'ventas.orden.agregar_item'},
  );
}

class _Sales extends SalesViewModel {
  @override
  CurrentOrderState build() => const CurrentOrderState();
  @override
  Future<bool> ensureCashSessionOpen() async => true;
  // La recarga posterior al cobro nunca llegó (red, app cerrada).
  @override
  Future<void> refreshOrder({bool clearIfPaid = false}) async {}
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
  @override
  Future<void> load(String businessId) async {}
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

  /// Lo que la pantalla cargó (antes del cobro).
  final bundles = <String, _Bundle>{};

  /// Lo que el servidor tiene AHORA (getOrder).
  final serverOrders = <String, Order>{};
  Object? getOrderError;
  final readOrders = <String>[];
  final closed = <(String, String)>[];

  @override
  Future<_Bundle> getOrderBundle(String orderId, {String? businessId}) async {
    final bundle = bundles[orderId];
    if (bundle != null) return bundle;
    throw TimeoutException('bundle sin respuesta');
  }

  @override
  Future<Order?> getOrder(String orderId, {String? businessId}) async {
    readOrders.add(orderId);
    final error = getOrderError;
    if (error != null) throw error;
    return serverOrders[orderId];
  }

  @override
  Future<void> closeOrder({
    required String orderId,
    required String status,
  }) async {
    closed.add((orderId, status));
  }

  /// fn_void_order_if_unpaid (20261009_0007). null = el servidor todavía no
  /// tiene la migración (PGRST202): se usa el cierre de siempre.
  String Function(String orderId)? voidIfUnpaid;
  final guardedVoids = <String>[];

  @override
  Future<String> voidOrderIfUnpaid(String orderId) async {
    final answer = voidIfUnpaid;
    if (answer == null) {
      throw const PostgrestException(
        message: 'Could not find the function public.fn_void_order_if_unpaid',
        code: 'PGRST202',
      );
    }
    guardedVoids.add(orderId);
    return answer(orderId);
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

OrderItem _item(String id, String orderId) => OrderItem.fromMap({
  'id': id,
  'order_id': orderId,
  'product_name': 'Producto $id',
  'product_id': 'product-$id',
  'qty': 1,
  'unit_price': 100,
  'subtotal': 100,
  'total': 100,
  'status': 'draft',
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

  /// Pestaña A con la venta [orderId] tal como se veía ANTES del cobro (3
  /// productos, abierta) y pestaña B con otra venta. A queda activa.
  Future<(ProviderContainer, SalesViewModel)> staleTab(
    String biz,
    String orderId,
    _Repository repository,
  ) async {
    repository.bundles[orderId] = (
      order: _order(orderId),
      items: [_item('a1', orderId), _item('a2', orderId), _item('a3', orderId)],
      checks: const <OrderCheck>[],
      customerId: null,
      customerName: null,
      note: null,
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
        RetailCart(slotId: 'quick-A', number: 1, orderId: orderId),
        const RetailCart(
          slotId: 'quick-B',
          number: 2,
          orderId: 'local-order-b',
        ),
      ].map((cart) => cart.toMap()).toList(),
      activeSlotId: 'quick-A',
    );
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(_Sales.new),
        currentBusinessModelProvider.overrideWithValue(BusinessModel.retail),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        byZoneVmProvider.overrideWith(_Zones.new),
        fiscalServiceProvider.overrideWithValue(_Fiscal()),
        salesRepositoryProvider.overrideWithValue(repository),
        printingServiceProvider.overrideWithValue(PrintingService(client)),
      ],
    );
    addTearDown(c.dispose);
    final vm = c.read(currentOrderProvider.notifier);
    expect(await vm.restoreRetailCarts(), isTrue);
    final shown = c.read(currentOrderProvider);
    expect(shown.order?.id, orderId);
    expect(shown.order?.status, 'open', reason: 'pantalla previa al cobro');
    expect(shown.items, hasLength(3));
    return (c, vm);
  }

  Future<OfflineQueueSyncResult> replay(String biz, _Repository repository) =>
      offline.syncPendingActions(
        businessId: biz,
        salesRepository: repository,
        printingService: PrintingService(client),
        inventoryRepository: InventoryRepository(client),
        cashierRepository: CashierRepository(client),
        force: false,
      );

  Future<List<String>> queuedVoids(String biz) async =>
      (await offline.unsettledActions(biz))
          .where((a) => a['type'] == 'void_order')
          .map((a) => a['order_id'].toString())
          .toList();

  test(
    'en línea: el servidor dice cobrada → solo se retira la pestaña',
    () async {
      const biz = 'retail-stale-paid-online';
      const orderId = 'order-sold';
      final repository = _Repository(client)
        ..serverOrders[orderId] = _order(
          orderId,
          status: 'paid',
          closedAt: '2026-10-09T12:30:00Z',
        );
      final (c, vm) = await staleTab(biz, orderId, repository);

      await vm.closeRetailCart('quick-A');

      expect(repository.readOrders, [orderId]);
      expect(
        repository.closed,
        isEmpty,
        reason: 'la venta cobrada no se anula',
      );
      expect(await queuedVoids(biz), isEmpty);
      expect(c.read(retailCartsProvider).carts.map((cart) => cart.slotId), [
        'quick-B',
      ]);
      expect(c.read(currentOrderProvider).order?.id, 'local-order-b');
      expect(
        await offline.isOrderClosedLocally(businessId: biz, orderId: orderId),
        isTrue,
      );
    },
  );

  test('la lectura falla: no anula en línea; el void encolado omite la venta '
      'cobrada al subir', () async {
    const biz = 'retail-stale-read-fails';
    const orderId = 'order-sold-2';
    final repository = _Repository(client)
      ..getOrderError = TimeoutException('sin respuesta');
    final (c, vm) = await staleTab(biz, orderId, repository);

    await vm.closeRetailCart('quick-A');

    expect(repository.closed, isEmpty, reason: 'nada se anula en línea');
    expect(await queuedVoids(biz), [orderId]);
    expect(c.read(retailCartsProvider).carts.map((cart) => cart.slotId), [
      'quick-B',
    ]);

    // Al subir, el servidor dice que la venta se cobró: se omite.
    repository
      ..getOrderError = null
      ..serverOrders[orderId] = _order(orderId, status: 'paid');
    final result = await replay(biz, repository);
    expect(repository.closed, isEmpty);
    expect(result.conflicts.single.actionType, 'void_order');
    expect(await offline.pendingActionsCount(biz), 0);
  });

  test('sin red: no lee ni anula en línea; el void encolado omite la venta '
      'cobrada al subir', () async {
    const biz = 'retail-stale-offline';
    const orderId = 'order-sold-3';
    final repository = _Repository(client);
    final (_, vm) = await staleTab(biz, orderId, repository);
    ConnectivityService().simulateDisconnect();
    try {
      await vm.closeRetailCart('quick-A');
    } finally {
      ConnectivityService().simulateReconnect();
    }

    expect(repository.readOrders, isEmpty);
    expect(repository.closed, isEmpty);
    expect(await queuedVoids(biz), [orderId]);

    repository.serverOrders[orderId] = _order(orderId, status: 'paid');
    await replay(biz, repository);
    expect(repository.closed, isEmpty);
    expect(await offline.pendingActionsCount(biz), 0);
  });

  test('el servidor confirma que sigue abierta: se anula en línea', () async {
    const biz = 'retail-open-confirmed';
    const orderId = 'order-still-open';
    final repository = _Repository(client)
      ..serverOrders[orderId] = _order(orderId);
    final (c, vm) = await staleTab(biz, orderId, repository);

    await vm.closeRetailCart('quick-A');

    expect(repository.readOrders, [orderId]);
    expect(repository.closed, [(orderId, 'void')]);
    expect(await queuedVoids(biz), isEmpty);
    expect(c.read(retailCartsProvider).carts.map((cart) => cart.slotId), [
      'quick-B',
    ]);
  });

  group('con la anulación protegida en el servidor (20261009_0007)', () {
    test('sigue abierta y sin cobros: la anula el servidor, sin cierre aparte',
        () async {
      const biz = 'retail-guarded-voided';
      const orderId = 'order-guarded-open';
      final repository = _Repository(client)
        ..serverOrders[orderId] = _order(orderId)
        ..voidIfUnpaid = (_) => 'voided';
      final (c, vm) = await staleTab(biz, orderId, repository);

      await vm.closeRetailCart('quick-A');

      expect(repository.guardedVoids, [orderId]);
      expect(repository.closed, isEmpty);
      expect(await queuedVoids(biz), isEmpty);
      expect(c.read(retailCartsProvider).carts.map((cart) => cart.slotId), [
        'quick-B',
      ]);
    });

    test('otra caja la cobró después de la lectura: no se anula y solo se '
        'retira la pestaña', () async {
      const biz = 'retail-guarded-closed';
      const orderId = 'order-paid-in-between';
      final repository = _Repository(client)
        // La lectura todavía la ve abierta; el servidor ya la tiene cobrada.
        ..serverOrders[orderId] = _order(orderId)
        ..voidIfUnpaid = (_) => 'already_closed';
      final (c, vm) = await staleTab(biz, orderId, repository);

      await vm.closeRetailCart('quick-A');

      expect(repository.guardedVoids, [orderId]);
      expect(repository.closed, isEmpty);
      expect(await queuedVoids(biz), isEmpty);
      expect(c.read(retailCartsProvider).carts.map((cart) => cart.slotId), [
        'quick-B',
      ]);
    });

    test('tiene un cobro parcial: no se anula y la pestaña se queda con sus '
        'productos', () async {
      const biz = 'retail-guarded-partial';
      const orderId = 'order-partially-paid';
      final repository = _Repository(client)
        ..serverOrders[orderId] = _order(orderId)
        ..voidIfUnpaid = (_) => 'has_payments';
      final (c, vm) = await staleTab(biz, orderId, repository);

      await vm.closeRetailCart('quick-A');

      expect(repository.guardedVoids, [orderId]);
      expect(repository.closed, isEmpty);
      expect(await queuedVoids(biz), isEmpty);
      expect(c.read(retailCartsProvider).carts.map((cart) => cart.slotId), [
        'quick-A',
        'quick-B',
      ]);
      final shown = c.read(currentOrderProvider);
      expect(shown.order?.id, orderId);
      expect(shown.items, hasLength(3));
      expect(shown.error, contains('tiene cobros'));
    });
  });

  test('la anulación explícita de una venta cobrada (annulOrder, con motivo) '
      'sigue anulándola', () async {
    const orderId = 'order-paid-annul';
    final requests = <(String, String, Object?)>[];
    final annulClient = SupabaseClient(
      'http://localhost:54321',
      'test',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        final body = request.body.isEmpty ? null : jsonDecode(request.body);
        requests.add((request.method, path, body));
        Object? response = <Object>[];
        if (request.method == 'GET' && path.endsWith('/payments')) {
          response = [
            {'id': 'pay-1', 'amount': 100, 'session_id': 'cash-1'},
          ];
        } else if (path.endsWith('/rpc/fn_close_order_and_table')) {
          response = null;
        } else if (request.method == 'PATCH' &&
            path.endsWith('/fiscal_documents')) {
          response = [
            {'id': 'fd-1'},
          ];
        }
        return http.Response(
          jsonEncode(response),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    addTearDown(annulClient.dispose);

    final cancelledDocs = await SalesRepository(
      annulClient,
    ).annulOrder(orderId: orderId, reason: 'Devolución del cliente');

    expect(cancelledDocs, ['fd-1']);
    final close = requests.singleWhere(
      (r) => r.$2.endsWith('/rpc/fn_close_order_and_table'),
    );
    expect(close.$3, {'p_order_id': orderId, 'p_status': 'void'});
    expect(
      requests.where((r) => r.$1 == 'PATCH' && r.$2.endsWith('/payments')),
      hasLength(1),
      reason: 'el pago cobrado queda cancelado',
    );
    final fiscalPatch = requests.singleWhere(
      (r) => r.$1 == 'PATCH' && r.$2.endsWith('/fiscal_documents'),
    );
    expect(
      (fiscalPatch.$3 as Map)['cancellation_reason'],
      'Devolución del cliente',
    );
    // La anulación explícita no consulta el estado para frenarse: anula la
    // venta aunque esté cobrada.
    expect(requests.where((r) => r.$2.endsWith('/orders')), isEmpty);
  });
}
