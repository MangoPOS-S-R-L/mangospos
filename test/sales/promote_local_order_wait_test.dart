// "Pagar" en una venta local (local-order-…) ya con internet: se sube antes
// del cobro. Tras un corte largo, la pasada forzada espera la pasada en curso
// con todo el atraso y luego corre la suya: el cliente podía esperar minutos
// en el mostrador sin ninguna señal. Ahora la espera tiene tope (luego se
// cobra por el camino offline de siempre, sin perder nada) y el banner dice
// que se está subiendo la venta.

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
import 'package:mangopos/core/offline/hub/hub_state_db.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/fiscal_models.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/presentation/inventory/viewmodel/inventory_viewmodel.dart';
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
  _Sales(this.initial);
  final CurrentOrderState initial;

  @override
  CurrentOrderState build() => initial;

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

  @override
  Future<void> load(String businessId) async {}
}

class _Fiscal implements FiscalService {
  @override
  Future<List<FiscalNcfSequence>> getSequences(String businessId) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repository extends SalesRepository {
  _Repository(super.client);

  final added = <String>[];

  /// Detiene la PRIMERA alta (la pasada con el atraso del corte).
  Completer<void>? holdFirstAdd;

  @override
  Future<Map<String, dynamic>> openRetailCart({
    required String slot,
    required String businessId,
    int peopleCount = 1,
  }) async => {'order_id': 'remote-$slot'};

  @override
  Future<({String itemId, bool replayed, bool itemExists})>
  addItemFromMenuIdempotent({
    required String clientOpId,
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
    String? createdByEmployeeId,
  }) async {
    added.add(orderId);
    final hold = holdFirstAdd;
    if (hold != null && added.length == 1) await hold.future;
    return (
      itemId: 'remote-item-${added.length}',
      replayed: false,
      itemExists: true,
    );
  }

  @override
  Future<
    ({
      Order? order,
      List<OrderItem> items,
      List<OrderCheck> checks,
      String? customerId,
      String? customerName,
      String? note,
    })
  >
  getOrderBundle(String orderId, {String? businessId}) async {
    throw TimeoutException('bundle sin respuesta');
  }
}

CurrentOrderState _sale(String id) => CurrentOrderState(
  origin: 'quick',
  order: Order.fromMap({
    'id': id,
    'session_id': 'session-$id',
    'status_ext': 'draft',
    'subtotal': 100,
    'total': 100,
    'created_at': '2026-10-09T12:00:00Z',
  }),
  items: [
    OrderItem.fromMap({
      'id': 'tmp_$id',
      'order_id': id,
      'product_name': 'Producto',
      'qty': 1,
      'unit_price': 100,
      'subtotal': 100,
      'total': 100,
      'status': 'draft',
      'created_at': '2026-10-09T12:00:00Z',
    }),
  ],
);

http.Response _emptyResponse(http.BaseRequest request) => http.Response(
  request.method == 'GET' ? '[]' : 'null',
  200,
  headers: {'content-type': 'application/json'},
  request: request as http.Request,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final offline = OfflinePosService();
  final keys = <String, String>{};
  late OfflineQueueDb db;
  late HubStateDb hubDb;
  late SupabaseClient client;
  late _Repository repository;
  final defaultBudget = SalesViewModel.promoteSyncBudget;

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
    hubDb = HubStateDb.inMemory(NativeDatabase.memory());
    HubStateDb.debugInstance = hubDb;
    client = SupabaseClient(
      'http://localhost:54321',
      'test',
      httpClient: MockClient((_) async => throw TimeoutException('no WAN')),
    );
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient((request) async => _emptyResponse(request)),
    );
  });

  setUp(() {
    repository = _Repository(client);
    offline.setHubUploader(null);
    ConnectivityService().simulateReconnect();
  });

  tearDown(() => SalesViewModel.promoteSyncBudget = defaultBudget);

  tearDownAll(() async {
    await db.close();
    await hubDb.close();
    await client.dispose();
    await Supabase.instance.dispose();
  });

  ProviderContainer container(String biz, CurrentOrderState initial) {
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(() => _Sales(initial)),
        currentBusinessModelProvider.overrideWithValue(
          BusinessModel.restaurant,
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        byZoneVmProvider.overrideWith(_Zones.new),
        fiscalServiceProvider.overrideWithValue(_Fiscal()),
        salesRepositoryProvider.overrideWithValue(repository),
        printingServiceProvider.overrideWithValue(PrintingService(client)),
        inventoryRepositoryProvider.overrideWithValue(
          InventoryRepository(client),
        ),
        cashierRepositoryProvider.overrideWithValue(CashierRepository(client)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> enqueueSale(String biz, String localOrderId) =>
      offline.enqueueAction(
        businessId: biz,
        action: {
          'type': 'add_item',
          'origin': 'quick',
          'order_id': localOrderId,
          'item_id': 'tmp_$localOrderId',
          'menu_item_id': 'product',
          'qty': 1,
        },
      );

  test('pasada larga en curso: "Pagar" espera con tope y con aviso visible, '
      'cae al cobro offline y la venta sube después sin perder nada', () async {
    const biz = 'promote-bounded-wait';
    const payingId = 'local-order-paying';
    SalesViewModel.promoteSyncBudget = const Duration(milliseconds: 300);
    final c = container(biz, _sale(payingId));
    final vm = c.read(currentOrderProvider.notifier);

    // Atraso del corte: la pasada de reconexión se queda subiendo otra venta.
    repository.holdFirstAdd = Completer<void>();
    await enqueueSale(biz, 'local-order-backlog');
    await enqueueSale(biz, payingId);
    final reconnectPass = vm.syncPendingOfflineActions();
    for (var i = 0; i < 400 && repository.added.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(repository.added, ['remote-quick-backlog']);

    final statuses = <String?>[];
    final inFlight = <bool>[];
    c.listen<CurrentOrderState>(currentOrderProvider, (_, next) {
      statuses.add(next.syncStatus);
      inFlight.add(next.syncInFlight);
    });

    final started = DateTime.now();
    final remoteId = await vm
        .promoteLocalOrderForPayment(payingId)
        .timeout(const Duration(seconds: 5));
    final waited = DateTime.now().difference(started);

    expect(remoteId, isNull, reason: 'se cobra por el camino offline');
    expect(waited, lessThan(const Duration(seconds: 5)));
    expect(statuses, contains('Subiendo la venta para cobrarla...'));
    expect(inFlight, contains(isTrue));
    expect(vm.isPromotingLocalOrder, isFalse);
    expect(
      c.read(currentOrderProvider).syncStatus,
      isNot('Subiendo la venta para cobrarla...'),
      reason: 'el aviso se quita al terminar',
    );
    expect(c.read(currentOrderProvider).order?.id, payingId);

    // La pasada sigue en segundo plano: al terminar sube también esta venta.
    repository.holdFirstAdd!.complete();
    await reconnectPass;
    for (var i = 0; i < 400; i++) {
      if (await offline.pendingActionsCount(biz) == 0 &&
          !c.read(currentOrderProvider).syncInFlight) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await offline.pendingActionsCount(biz), 0);
    expect(c.read(currentOrderProvider).syncInFlight, isFalse);
    expect(repository.added, ['remote-quick-backlog', 'remote-quick-paying']);
  });

  test(
    'sin pasada en curso: sube la venta dentro del tope (como siempre)',
    () async {
      const biz = 'promote-no-backlog';
      const payingId = 'local-order-fast';
      final c = container(biz, _sale(payingId));
      final vm = c.read(currentOrderProvider.notifier);
      await enqueueSale(biz, payingId);

      await vm
          .promoteLocalOrderForPayment(payingId)
          .timeout(const Duration(seconds: 5));

      expect(repository.added, ['remote-quick-fast']);
      expect(
        await offline.mappedRemoteOrderId(
          businessId: biz,
          localOrderId: payingId,
        ),
        'remote-quick-fast',
      );
      expect(await offline.pendingActionsCount(biz), 0);
      expect(vm.isPromotingLocalOrder, isFalse);
      expect(
        c.read(currentOrderProvider).syncStatus,
        isNot('Subiendo la venta para cobrarla...'),
      );
    },
  );
}
