// Sincronización automática con internet = silenciosa: una pasada automática
// (uplink, reconexión) solo mueve los contadores del badge/banner; no publica
// resultado (snackbar), no escribe el error de la venta y no recarga la venta
// activa si no completó nada. "Sincronizar ahora" (force) sí muestra su
// resultado y, si llega con otra pasada en curso, espera a una pasada real.

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
import 'package:mangopos/core/offline/offline_queue_status_provider.dart';
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

  final loaded = <String>[];
  final added = <String>[];

  /// Detiene la PRIMERA alta hasta completarse (pasada en curso).
  Completer<void>? holdFirstAdd;

  // Venta rápida local: sube por su carrito ('quick-<id>').
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
    loaded.add(orderId);
    throw TimeoutException('bundle sin respuesta');
  }
}

/// Ajuste de inventario que el servidor rechaza (error de negocio).
class _RejectingInventory extends InventoryRepository {
  _RejectingInventory(super.client);

  int calls = 0;

  @override
  Future<void> adjustInventory({
    required String businessId,
    required String warehouseId,
    required String itemId,
    required double countedQuantity,
    required String reasonCode,
    String? notes,
    double? costPerUnit,
    bool queueOnNetworkFailure = true,
  }) async {
    calls++;
    throw Exception('violates check constraint "qty_positive"');
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
  late _RejectingInventory inventory;

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
    // La recarga de la venta activa puede llegar a Realtime.
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient((request) async => _emptyResponse(request)),
    );
  });

  setUp(() {
    repository = _Repository(client);
    inventory = _RejectingInventory(client);
    offline.setHubUploader(null);
    ConnectivityService().simulateReconnect();
  });

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
        inventoryRepositoryProvider.overrideWithValue(inventory),
        cashierRepositoryProvider.overrideWithValue(CashierRepository(client)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> enqueueSale(
    String biz,
    String localOrderId, {
    String? status,
    int? attempts,
    String? nextRetryAt,
  }) => offline.enqueueAction(
    businessId: biz,
    action: {
      'type': 'add_item',
      'origin': 'quick',
      'order_id': localOrderId,
      'item_id': 'tmp_$localOrderId',
      'menu_item_id': 'product',
      'qty': 1,
      'status': ?status,
      'attempts': ?attempts,
      'next_retry_at': ?nextRetryAt,
    },
  );

  String inOneHour() =>
      DateTime.now().add(const Duration(hours: 1)).toIso8601String();

  test('pasada automática sin nada completado: sin aviso ni recarga; '
      '"Sincronizar ahora" sí sube y muestra su resultado', () async {
    const biz = 'silent-nothing-completed';
    final initial = _sale('order-active-auto');
    final c = container(biz, initial);
    await enqueueSale(
      biz,
      'local-order-waiting',
      status: 'failed',
      attempts: 1,
      nextRetryAt: inOneHour(),
    );
    expect(await offline.hasActionsReadyToSync(biz), isFalse);

    final vm = c.read(currentOrderProvider.notifier);
    await vm.syncPendingOfflineActions();
    final status = c.read(offlineQueueStatusProvider);
    expect(status.lastResult, isNull, reason: 'automática: sin snackbar');
    expect(status.pending, 1, reason: 'el badge sigue al día');
    expect(repository.added, isEmpty);
    expect(repository.loaded, isEmpty, reason: 'no completó nada');
    expect(c.read(currentOrderProvider).order?.id, initial.order!.id);
    expect(c.read(currentOrderProvider).error, isNull);

    await vm.syncPendingOfflineActions(force: true);
    final forced = c.read(offlineQueueStatusProvider).lastResult;
    expect(forced, isNotNull, reason: 'force muestra su resultado');
    expect(forced!.completed, 1);
    expect(c.read(offlineQueueStatusProvider).pending, 0);
    expect(repository.added, ['remote-quick-waiting']);
    // Completó algo: ahí sí recarga la venta activa.
    expect(repository.loaded, [initial.order!.id]);
  });

  test('reconexión: silenciosa, pero recarga la venta activa', () async {
    const biz = 'silent-reconnect-reload';
    final initial = _sale('order-active-reconnect');
    final c = container(biz, initial);
    await enqueueSale(
      biz,
      'local-order-reconnect',
      status: 'failed',
      attempts: 1,
      nextRetryAt: inOneHour(),
    );
    await c
        .read(currentOrderProvider.notifier)
        .syncPendingOfflineActions(reloadActiveOrder: true);
    expect(c.read(offlineQueueStatusProvider).lastResult, isNull);
    expect(c.read(offlineQueueStatusProvider).pending, 1);
    expect(repository.loaded, [initial.order!.id]);
    expect(c.read(currentOrderProvider).error, isNull);
  });

  test('fallos y dead-letter en una pasada automática: sin aviso ni error en '
      'la venta, contadores al día; force sí avisa', () async {
    const biz = 'silent-failures-dead';
    final c = container(biz, _sale('local-order-active-dead'));
    // Le queda un intento: este fallo la manda a dead-letter.
    await offline.enqueueAction(
      businessId: biz,
      action: {
        'type': 'inventory_adjust',
        'warehouse_id': 'w1',
        'item_id': 'i-dead',
        'counted_quantity': 5,
        'reason_code': 'correction',
        'attempts': OfflinePosService.maxAttempts - 1,
      },
    );
    // Primer intento de esta: queda failed con backoff.
    await offline.enqueueAction(
      businessId: biz,
      action: {
        'type': 'inventory_adjust',
        'warehouse_id': 'w1',
        'item_id': 'i-failed',
        'counted_quantity': 5,
        'reason_code': 'correction',
      },
    );
    // Cada error que la venta llegó a mostrar, aunque fuera un instante.
    final errors = <String>[];
    c.listen<CurrentOrderState>(currentOrderProvider, (_, next) {
      final error = next.error;
      if (error != null) errors.add(error);
    });
    final vm = c.read(currentOrderProvider.notifier);
    await vm.syncPendingOfflineActions();
    expect(inventory.calls, 2, reason: 'la pasada sí corrió');
    final status = c.read(offlineQueueStatusProvider);
    expect(status.lastResult, isNull, reason: 'automática: sin snackbar');
    expect(status.dead, 1);
    expect(status.pending, 1);
    expect(errors, isEmpty, reason: 'automática: sin aviso de error');

    await vm.syncPendingOfflineActions(force: true);
    final forced = c.read(offlineQueueStatusProvider).lastResult;
    expect(forced, isNotNull, reason: 'force muestra su resultado');
    expect(forced!.hasFailures, isTrue);
    expect(forced.dead, 1);
    expect(errors, contains(startsWith('Sync offline parcial')));
  });

  test('"Sincronizar ahora" durante una pasada automática espera una pasada '
      'real que sube lo encolado después', () async {
    const biz = 'force-waits-real-pass';
    final c = container(biz, _sale('local-order-active-force'));
    final vm = c.read(currentOrderProvider.notifier);
    repository.holdFirstAdd = Completer<void>();
    await enqueueSale(biz, 'local-order-held');

    final automatic = vm.syncPendingOfflineActions();
    for (var i = 0; i < 400 && repository.added.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(repository.added, ['remote-quick-held']);

    // Entra DESPUÉS de que la pasada en curso leyó la cola.
    await enqueueSale(biz, 'local-order-second');
    var forceDone = false;
    final forced = vm
        .syncPendingOfflineActions(force: true)
        .then((_) => forceDone = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(forceDone, isFalse, reason: 'no regresa sin sincronizar');

    repository.holdFirstAdd!.complete();
    await automatic;
    await forced.timeout(const Duration(seconds: 5));
    expect(repository.added, ['remote-quick-held', 'remote-quick-second']);
    final shown = c.read(offlineQueueStatusProvider).lastResult;
    expect(shown, isNotNull, reason: 'el resultado del force sí se muestra');
    expect(shown!.completed, 1);
    expect(shown.pending, 0);
    expect(await offline.pendingActionsCount(biz), 0);
  });

  test('pedido force pendiente y la pantalla se descarta: no se queda '
      'esperando ni corre otra pasada sin dueño', () async {
    const biz = 'force-rerun-after-dispose';
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(
          () => _Sales(_sale('local-order-active-dispose')),
        ),
        currentBusinessModelProvider.overrideWithValue(
          BusinessModel.restaurant,
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        byZoneVmProvider.overrideWith(_Zones.new),
        fiscalServiceProvider.overrideWithValue(_Fiscal()),
        salesRepositoryProvider.overrideWithValue(repository),
        printingServiceProvider.overrideWithValue(PrintingService(client)),
        inventoryRepositoryProvider.overrideWithValue(inventory),
        cashierRepositoryProvider.overrideWithValue(CashierRepository(client)),
      ],
    );
    final vm = c.read(currentOrderProvider.notifier);
    repository.holdFirstAdd = Completer<void>();
    await enqueueSale(biz, 'local-order-held-dispose');
    final automatic = vm.syncPendingOfflineActions().catchError((_) {});
    for (var i = 0; i < 400 && repository.added.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await enqueueSale(biz, 'local-order-after-dispose');
    final forced = vm.syncPendingOfflineActions(force: true);
    c.dispose();
    repository.holdFirstAdd!.complete();
    await automatic;
    await forced.timeout(const Duration(seconds: 5));
    expect(repository.added, ['remote-quick-held-dispose']);
    // La venta encolada después sigue en la cola para la próxima pasada.
    expect(await offline.pendingActionsCount(biz), 1);
  });

  // Integración con el banner de Ventas: tras la pasada, la venta no puede
  // quedar con «Todo sincronizado.» como estado; sin estado, el banner usa su
  // texto propio, que con muertas las cuenta (sales_sync_banner_dead_test).
  test('pasada sin trabajo con solo operaciones muertas: el banner no dice '
      '«Todo sincronizado.» y sigue sin aviso', () async {
    const biz = 'silent-dead-only-banner';
    final c = container(biz, _sale('order-active-dead-only'));
    // Ya agotó sus reintentos: no se reintenta sola ni cuenta como pendiente.
    await offline.enqueueAction(
      businessId: biz,
      action: {
        'type': 'inventory_adjust',
        'warehouse_id': 'w1',
        'item_id': 'i-dead-only',
        'counted_quantity': 5,
        'reason_code': 'correction',
        'status': 'dead',
        'attempts': OfflinePosService.maxAttempts,
      },
    );
    final errors = <String>[];
    c.listen<CurrentOrderState>(currentOrderProvider, (_, next) {
      final error = next.error;
      if (error != null) errors.add(error);
    });

    await c.read(currentOrderProvider.notifier).syncPendingOfflineActions();
    expect(inventory.calls, 0, reason: 'la muerta no se reintenta sola');
    final status = c.read(offlineQueueStatusProvider);
    expect(status.lastResult, isNull, reason: 'automática: sin snackbar');
    expect(status.dead, 1);
    final sale = c.read(currentOrderProvider);
    expect(sale.pendingOfflineActions, 0);
    expect(sale.syncStatus, isNot('Todo sincronizado.'));
    expect(errors, isEmpty, reason: 'automática: sin aviso de error');
  });
}
