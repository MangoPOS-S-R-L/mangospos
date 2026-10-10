import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/fiscal_models.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/by_zone_state.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
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
  SessionState build() => SessionState(activeBusinessId: businessId);
}

class _Sales extends SalesViewModel {
  @override
  CurrentOrderState build() => const CurrentOrderState();

  @override
  Future<bool> ensureCashSessionOpen() async => true;
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

class _Repository extends SalesRepository {
  _Repository(super.client);

  final addressStarted = Completer<void>();
  final delayedAddress = Completer<String?>();
  bool failAddress = false;

  @override
  Future<OpenTableResult> openTableAndLoad({
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    final source = _sale(tableId);
    final orderId = 'remote-order-$tableId';
    return (
      orderId: orderId,
      bundle: (
        order: source.order!.copyWith(id: orderId, status: 'open'),
        items: source.items
            .map((item) => item.copyWith(orderId: orderId))
            .toList(),
        checks: <OrderCheck>[],
        customerId: null,
        customerName: null,
        note: null,
      ),
    );
  }

  @override
  Future<String?> getSessionDeliveryAddress(
    String sessionId, {
    String? businessId,
  }) async {
    if (failAddress) throw TimeoutException('address offline');
    if (sessionId == 'session-delivery-one') {
      addressStarted.complete();
      return delayedAddress.future;
    }
    return 'Dirección del segundo pedido';
  }
}

CurrentOrderState _sale(String tableId) => CurrentOrderState(
  origin: 'table',
  order: Order.fromMap({
    'id': 'local-order-$tableId',
    'session_id': 'session-$tableId',
    'status_ext': 'draft',
    'subtotal': 100,
    'total': 100,
    'created_at': '2026-10-09T12:00:00Z',
  }),
  items: [
    OrderItem.fromMap({
      'id': 'tmp_$tableId',
      'order_id': 'local-order-$tableId',
      'product_name': 'Producto $tableId',
      'qty': 1,
      'unit_price': 100,
      'subtotal': 100,
      'total': 100,
      'status': 'draft',
      'created_at': '2026-10-09T12:00:00Z',
    }),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final offline = OfflinePosService();
  final keys = <String, String>{};
  late OfflineQueueDb db;
  late SupabaseClient client;
  Completer<void>? promotionsStarted;
  Completer<http.Response>? delayedPromotions;
  http.Request? promotionsRequest;

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
            return null;
          },
        );
    db = OfflineQueueDb.inMemory(NativeDatabase.memory());
    OfflineQueueDb.debugInstance = db;
    client = SupabaseClient(
      'http://localhost:54321',
      'test',
      httpClient: MockClient((_) async => throw TimeoutException('no WAN')),
    );
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/promotions') &&
            delayedPromotions != null) {
          promotionsRequest = request;
          promotionsStarted!.complete();
          return delayedPromotions!.future;
        }
        return http.Response(
          request.url.path.endsWith('/taxes') ? '[]' : '{}',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
  });

  tearDownAll(() async {
    await db.close();
    await client.dispose();
    await Supabase.instance.dispose();
  });

  Future<ProviderContainer> prepare(String businessId, _Repository repo) async {
    await PosLookupOfflineCache().saveBusinessTaxes(businessId, []);
    for (final table in ['delivery-one', 'delivery-two']) {
      await offline.saveSnapshot(
        businessId: businessId,
        slotId: table,
        tableId: table,
        origin: 'table',
        state: _sale(table),
      );
    }
    ConnectivityService().simulateDisconnect();
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(businessId)),
        currentOrderProvider.overrideWith(_Sales.new),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        byZoneVmProvider.overrideWith(_Zones.new),
        fiscalServiceProvider.overrideWithValue(_Fiscal()),
        salesRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'dirección tardía no cambia una mesa ni sobrescribe el otro respaldo',
    () async {
      const businessId = 'delivery-to-table-navigation';
      final repository = _Repository(client);
      final container = await prepare(businessId, repository);
      final vm = container.read(currentOrderProvider.notifier);
      final opening = vm.openDeliveryOrder(
        tableId: 'delivery-one',
        deliveryType: 'own',
      );
      await repository.addressStarted.future;
      await vm.openTable('delivery-two');
      final second = container.read(currentOrderProvider);
      repository.delayedAddress.complete('Dirección del primer pedido');
      await opening;

      final visible = container.read(currentOrderProvider);
      expect(visible.order?.id, second.order?.id);
      expect(visible.items, second.items);
      expect(visible.origin, 'table');
      expect(visible.deliveryAddress, isNull);
      expect(visible.deliveryType, isNull);
      expect(
        (await offline.loadSnapshot(
          businessId: businessId,
          slotId: 'delivery-one',
        ))?.order?.id,
        'local-order-delivery-one',
      );
      expect(
        (await offline.loadSnapshot(
          businessId: businessId,
          slotId: 'delivery-two',
        ))?.order?.id,
        'local-order-delivery-two',
      );
    },
  );

  test(
    'dos deliveries solapados conservan tipo, dirección y cuenta activos',
    () async {
      const businessId = 'delivery-to-delivery-navigation';
      final repository = _Repository(client);
      final container = await prepare(businessId, repository);
      final vm = container.read(currentOrderProvider.notifier);
      final first = vm.openDeliveryOrder(
        tableId: 'delivery-one',
        deliveryType: 'own',
      );
      await repository.addressStarted.future;
      await vm.openDeliveryOrder(
        tableId: 'delivery-two',
        deliveryType: 'uber_eats',
      );
      repository.delayedAddress.complete('Dirección del primer pedido');
      await first;

      final visible = container.read(currentOrderProvider);
      expect(visible.order?.id, 'local-order-delivery-two');
      expect(visible.deliveryType, 'uber_eats');
      expect(visible.deliveryAddress, 'Dirección del segundo pedido');
      final saved = await offline.loadSnapshot(
        businessId: businessId,
        slotId: 'delivery-two',
      );
      expect(saved?.order?.id, visible.order?.id);
      expect(saved?.deliveryAddress, visible.deliveryAddress);
      expect(
        (await offline.loadSnapshot(
          businessId: businessId,
          slotId: 'delivery-one',
        ))?.order?.id,
        'local-order-delivery-one',
      );
    },
  );

  test(
    'promociones tardías no guardan otra mesa bajo el respaldo anterior',
    () async {
      const businessId = 'late-promotions-table-navigation';
      final repository = _Repository(client);
      final container = await prepare(businessId, repository);
      final vm = container.read(currentOrderProvider.notifier);
      promotionsStarted = Completer<void>();
      delayedPromotions = Completer<http.Response>();
      ConnectivityService().simulateReconnect();

      final opening = vm.openTable('delivery-one');
      await promotionsStarted!.future;
      expect(
        container.read(currentOrderProvider).order?.id,
        'remote-order-delivery-one',
      );
      ConnectivityService().simulateDisconnect();
      await vm.openTable('delivery-two');
      delayedPromotions!.complete(
        http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
          request: promotionsRequest,
        ),
      );
      await opening;

      expect(
        container.read(currentOrderProvider).order?.id,
        'local-order-delivery-two',
      );
      expect(
        (await offline.loadSnapshot(
          businessId: businessId,
          slotId: 'delivery-one',
        ))?.order?.id,
        'local-order-delivery-one',
      );
      expect(
        (await offline.loadSnapshot(
          businessId: businessId,
          slotId: 'delivery-two',
        ))?.order?.id,
        'local-order-delivery-two',
      );
      promotionsStarted = null;
      delayedPromotions = null;
    },
  );

  test('reabrir delivery sin red conserva su dirección guardada', () async {
    const businessId = 'delivery-offline-address-reopen';
    final repository = _Repository(client)..failAddress = true;
    final container = await prepare(businessId, repository);
    final saved = _sale('delivery-one').copyWith(
      origin: 'delivery',
      deliveryType: 'own',
      deliveryAddress: 'Dirección guardada del cliente',
    );
    await offline.saveSnapshot(
      businessId: businessId,
      slotId: 'delivery-one',
      tableId: 'delivery-one',
      origin: 'delivery',
      state: saved,
    );
    await container
        .read(currentOrderProvider.notifier)
        .openDeliveryOrder(tableId: 'delivery-one', deliveryType: 'own');

    final visible = container.read(currentOrderProvider);
    expect(visible.order?.id, saved.order?.id);
    expect(visible.deliveryAddress, saved.deliveryAddress);
    expect(
      (await offline.loadSnapshot(
        businessId: businessId,
        slotId: 'delivery-one',
      ))?.deliveryAddress,
      saved.deliveryAddress,
    );
  });
}
