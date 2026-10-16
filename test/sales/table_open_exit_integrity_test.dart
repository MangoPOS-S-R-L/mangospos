// Salir mientras abre una mesa no puede dejar su cuenta vacía ocupándola.
// La respuesta tardía se limpia por su identidad, sin pintar la cuenta en
// otra visita ni liberar una mesa que el usuario ya volvió a abrir.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/business_settings_offline_cache.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/by_zone_state.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _tableA = '0e170000-0000-4000-8000-000000000001';
const _tableB = '0e170000-0000-4000-8000-000000000002';
const _orderA = '0e180000-0000-4000-8000-000000000001';
const _orderB = '0e180000-0000-4000-8000-000000000002';

class _Session extends SessionController {
  _Session(this.businessId);
  final String businessId;

  @override
  SessionState build() => SessionState(
    activeBusinessId: businessId,
    activeBusinessName: 'Salón',
    userName: 'Caja',
    permissions: {'ventas.orden.agregar_item', 'caja.apertura'},
  );

  void switchTo(String nextBusinessId) => state = SessionState(
    activeBusinessId: nextBusinessId,
    permissions: {'ventas.orden.agregar_item', 'caja.apertura'},
  );
}

class _Sales extends SalesViewModel {
  Completer<void>? cashGate;
  final cashCheckStarted = Completer<void>();

  @override
  CurrentOrderState build() => const CurrentOrderState();

  void showForTest(CurrentOrderState selected) => state = selected;

  @override
  Future<bool> ensureCashSessionOpen() async {
    if (!cashCheckStarted.isCompleted) cashCheckStarted.complete();
    await cashGate?.future;
    return true;
  }
}

class _HubMode extends StateNotifier<TerminalMode>
    implements HubModeController {
  _HubMode(super.state);

  @override
  String? get reachableHubUrl =>
      state == TerminalMode.hubClient ? 'http://hub.local' : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Opening {
  _Opening(this.tableId);
  final String tableId;
  final started = Completer<void>();
  final response = Completer<OpenTableResult>();
}

class _Zones extends ByZoneViewModel {
  final loaded = <String>[];

  @override
  ByZoneState build() => const ByZoneState();

  @override
  Future<void> load(String businessId) async {
    loaded.add(businessId);
    state = state.copyWith(businessId: businessId);
  }
}

OpenTableResult _result(String orderId, {bool withItems = false}) => (
  orderId: orderId,
  bundle: (
    order: Order(
      id: orderId,
      sessionId: 'session-$orderId',
      status: 'open',
      subtotal: withItems ? 100 : 0,
      discounts: 0,
      serviceFee: 0,
      tax: 0,
      total: withItems ? 100 : 0,
      createdAt: DateTime(2026, 10, 16, 10),
    ),
    items: withItems
        ? [
            OrderItem(
              id: '0e190000-0000-4000-8000-000000000001',
              orderId: orderId,
              productId: 'producto',
              productName: 'Café',
              quantity: 1,
              unitPrice: 100,
              subtotal: 100,
              discounts: 0,
              tax: 0,
              total: 100,
              isTakeout: false,
              status: 'draft',
              createdAt: DateTime(2026, 10, 16, 10),
            ),
          ]
        : const <OrderItem>[],
    checks: const <OrderCheck>[],
    customerId: null,
    customerName: null,
    note: null,
  ),
);

class _Server extends SalesRepository {
  _Server(super.client);
  final planned = <_Opening>[];
  final cloudOpens = <String>[];
  final hubOpens = <String>[];
  final participations = <String>[];
  final released =
      <
        ({String orderId, String? businessId, String? deviceId, bool pending})
      >[];
  Object? releaseError;

  _Opening plan(String tableId) {
    final opening = _Opening(tableId);
    planned.add(opening);
    return opening;
  }

  Future<OpenTableResult> _respond(String tableId) async {
    final opening = planned.removeAt(0);
    expect(tableId, opening.tableId);
    opening.started.complete();
    return opening.response.future;
  }

  @override
  Future<OpenTableResult> openTableAndLoad({
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) {
    SalesRepository.cancelPendingEmptyTableRelease(tableId);
    cloudOpens.add(tableId);
    return _respond(tableId);
  }

  @override
  Future<OpenTableResult> openTableAndLoadViaHub({
    required String hubBaseUrl,
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) {
    SalesRepository.cancelPendingEmptyTableRelease(tableId);
    hubOpens.add(tableId);
    return _respond(tableId);
  }

  @override
  Future<void> registerSessionParticipant(
    String orderId,
    String deviceId,
  ) async {
    participations.add(orderId);
  }

  @override
  Future<bool> releaseEmptyTableIfNeeded(
    String orderId, {
    String? businessId,
    String? deviceId,
    bool hasPendingWork = true,
  }) async {
    released.add((
      orderId: orderId,
      businessId: businessId,
      deviceId: deviceId,
      pending: hasPendingWork,
    ));
    final error = releaseError;
    if (error != null) throw error;
    return !hasPendingWork;
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

Future<List<Map<String, dynamic>>> _waitForRelease(String businessId) async {
  var actions = <Map<String, dynamic>>[];
  for (var i = 0; i < 200; i++) {
    actions = await OfflinePosService().unsettledActions(businessId);
    if (actions.any((action) => action['type'] == 'release_empty_order')) {
      return actions;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('No se guardó la liberación pendiente de $businessId');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final offline = OfflinePosService();
  final secureStore = <String, String>{};
  final defaultOpenTimeout = SalesViewModel.tableOpenTimeout;
  late OfflineQueueDb db;
  late SupabaseClient client;

  http.Response emptyResponse(http.BaseRequest request) => http.Response(
    request.method == 'GET' ? '[]' : 'null',
    200,
    headers: {'content-type': 'application/json'},
    request: request,
  );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      'mangopos_unique_device_id': 'terminal-salon',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? const {};
            if (call.method == 'write') {
              secureStore[args['key'] as String] = args['value'] as String;
            }
            if (call.method == 'read') return secureStore[args['key']];
            if (call.method == 'containsKey') {
              return secureStore.containsKey(args['key']);
            }
            return null;
          },
        );
    db = OfflineQueueDb.inMemory(NativeDatabase.memory());
    OfflineQueueDb.debugInstance = db;
    client = SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: MockClient((request) async => emptyResponse(request)),
    );
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient((request) async => emptyResponse(request)),
    );
  });

  setUp(() {
    offline.setHubUploader(null);
    ConnectivityService().simulateReconnect();
  });

  tearDown(() => SalesViewModel.tableOpenTimeout = defaultOpenTimeout);

  tearDownAll(() async {
    ConnectivityService().simulateDisconnect();
    await db.close();
    await client.dispose();
    await Supabase.instance.dispose();
  });

  Future<(ProviderContainer, _Sales, _Server)> salon(
    String businessId, {
    TerminalMode mode = TerminalMode.cloud,
  }) async {
    await PosLookupOfflineCache().saveBusinessTaxes(businessId, []);
    await BusinessSettingsOfflineCache().saveRow(
      businessId: businessId,
      row: {},
    );
    final server = _Server(client);
    final vm = _Sales();
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(businessId)),
        currentOrderProvider.overrideWith(() => vm),
        hubModeProvider.overrideWith((ref) => _HubMode(mode)),
        salesRepositoryProvider.overrideWithValue(server),
        byZoneVmProvider.overrideWith(_Zones.new),
      ],
    );
    addTearDown(container.dispose);
    container.read(currentOrderProvider.notifier);
    return (container, vm, server);
  }

  test('salir mientras abre libera la cuenta vacía exacta de la respuesta '
      'tardía sin cargarla en pantalla', () async {
    const businessId = 'table-exit-late-empty';
    final (c, vm, server) = await salon(businessId);
    final shownOrders = <String>[];
    c.listen(currentOrderProvider, (_, next) {
      final id = next.order?.id;
      if (id != null) shownOrders.add(id);
    });
    final pending = server.plan(_tableA);
    final visit = Object();

    final opening = vm.openTable(_tableA, visitId: visit);
    await pending.started.future;
    vm.abandonTableOpening(visit);
    pending.response.complete(_result(_orderA));
    await opening;
    await _waitUntil(() => server.released.isNotEmpty);

    expect(server.released.map((r) => r.orderId), [_orderA]);
    expect(server.released.single.businessId, businessId);
    expect(server.released.single.deviceId, 'terminal-salon');
    expect(server.released.single.pending, isFalse);
    expect(shownOrders, isEmpty);
    expect(server.participations, isEmpty);
    expect(c.read(currentOrderProvider).order, isNull);
    expect(
      await offline.loadSnapshot(businessId: businessId, slotId: _tableA),
      isNull,
      reason: 'la respuesta abandonada no se guarda como cuenta activa',
    );
  });

  test('salir antes del RPC evita abrir la mesa en el servidor', () async {
    final (c, vm, server) = await salon('table-exit-before-rpc');
    final cashGate = vm.cashGate = Completer<void>();
    final visit = Object();

    final opening = vm.openTable(_tableA, visitId: visit);
    await vm.cashCheckStarted.future;
    vm.abandonTableOpening(visit);
    cashGate.complete();
    await opening;

    expect(server.cloudOpens, isEmpty);
    expect(server.hubOpens, isEmpty);
    expect(server.released, isEmpty);
    expect(c.read(currentOrderProvider).order, isNull);
  });

  test('la respuesta cruda que llega después del timeout también libera la '
      'mesa abandonada', () async {
    final (c, vm, server) = await salon('table-exit-after-timeout');
    SalesViewModel.tableOpenTimeout = const Duration(milliseconds: 20);
    final pending = server.plan(_tableA);
    final visit = Object();

    final opening = vm.openTable(_tableA, visitId: visit);
    await pending.started.future;
    vm.abandonTableOpening(visit);
    await opening.timeout(const Duration(seconds: 1));
    expect(server.released, isEmpty);
    expect(c.read(currentOrderProvider).order, isNull);

    // El Future que vio el timeout ya terminó, pero el RPC siguió en curso.
    pending.response.complete(_result(_orderA));
    await _waitUntil(() => server.released.isNotEmpty);

    expect(server.released.map((r) => r.orderId), [_orderA]);
    expect(server.participations, isEmpty);
    expect(c.read(currentOrderProvider).order, isNull);
  });

  for (final firstRespondsFirst in [true, false]) {
    test('reabrir la misma mesa protege su cuenta aunque la visita anterior '
        'responda ${firstRespondsFirst ? 'primero' : 'después'}', () async {
      final (c, vm, server) = await salon(
        'table-exit-reopen-$firstRespondsFirst',
      );
      final first = server.plan(_tableA);
      final second = server.plan(_tableA);
      final firstVisit = Object();
      final secondVisit = Object();

      final firstOpen = vm.openTable(_tableA, visitId: firstVisit);
      await first.started.future;
      vm.abandonTableOpening(firstVisit);
      final secondOpen = vm.openTable(_tableA, visitId: secondVisit);
      await second.started.future;

      if (firstRespondsFirst) {
        first.response.complete(_result(_orderA));
        await firstOpen;
        expect(server.released, isEmpty);
        second.response.complete(_result(_orderA));
      } else {
        second.response.complete(_result(_orderA));
        await secondOpen;
        first.response.complete(_result(_orderA));
      }
      await firstOpen;
      await secondOpen;
      // Un dispose tardío de la primera ruta tampoco abandona la segunda.
      vm.abandonTableOpening(firstVisit);
      await Future<void>.delayed(const Duration(milliseconds: 550));

      expect(c.read(currentOrderProvider).order?.id, _orderA);
      expect(server.released, isEmpty);
      expect(server.cloudOpens, [_tableA, _tableA]);
    });
  }

  test('una reapertura que cancela la limpieza anterior y luego falla '
      'libera esa cuenta al salir', () async {
    final (c, vm, server) = await salon('table-exit-failed-reopen');
    final first = server.plan(_tableA);
    final second = server.plan(_tableA);
    final firstVisit = Object();
    final secondVisit = Object();

    final firstOpen = vm.openTable(_tableA, visitId: firstVisit);
    await first.started.future;
    vm.abandonTableOpening(firstVisit);
    first.response.complete(_result(_orderA));
    await firstOpen;
    expect(SalesRepository.pendingEmptyTableReleaseCount, 1);
    expect(server.released, isEmpty);

    // La reapertura cancela el timer por mesa, como el repositorio real.
    final secondOpen = vm.openTable(_tableA, visitId: secondVisit);
    await second.started.future;
    expect(SalesRepository.pendingEmptyTableReleaseCount, 0);
    second.response.completeError(StateError('MESA_NO_DISPONIBLE'));
    await secondOpen;
    expect(c.read(currentOrderProvider).order, isNull);
    vm.abandonTableOpening(secondVisit);
    await _waitUntil(() => server.released.isNotEmpty);

    expect(server.released.map((r) => r.orderId), [_orderA]);
    expect(server.cloudOpens, [_tableA, _tableA]);
  });

  test('abrir otra mesa libera solo la respuesta abandonada y conserva la '
      'cuenta seleccionada', () async {
    final (c, vm, server) = await salon('table-exit-other-table');
    final first = server.plan(_tableA);
    final second = server.plan(_tableB);
    final firstVisit = Object();

    final firstOpen = vm.openTable(_tableA, visitId: firstVisit);
    await first.started.future;
    vm.abandonTableOpening(firstVisit);
    final secondOpen = vm.openTable(_tableB, visitId: Object());
    await second.started.future;
    second.response.complete(_result(_orderB, withItems: true));
    await secondOpen;
    expect(c.read(currentOrderProvider).order?.id, _orderB);

    first.response.complete(_result(_orderA));
    await firstOpen;
    await _waitUntil(() => server.released.isNotEmpty);

    expect(server.released.map((r) => r.orderId), [_orderA]);
    expect(c.read(currentOrderProvider).order?.id, _orderB);
    expect(c.read(currentOrderProvider).items.single.productName, 'Café');
    expect(server.participations, isNot(contains(_orderA)));
  });

  test('una respuesta abandonada con productos conserva la mesa', () async {
    const businessId = 'table-exit-has-items';
    final (c, vm, server) = await salon(businessId);
    final pending = server.plan(_tableA);
    final visit = Object();

    final opening = vm.openTable(_tableA, visitId: visit);
    await pending.started.future;
    vm.abandonTableOpening(visit);
    pending.response.complete(_result(_orderA, withItems: true));
    await opening;
    await Future<void>.delayed(const Duration(milliseconds: 550));

    expect(server.released, isEmpty);
    expect(c.read(currentOrderProvider).order, isNull);
    expect(
      (await offline.unsettledActions(
        businessId,
      )).where((action) => action['type'] == 'release_empty_order'),
      isEmpty,
    );
  });

  test('una liberación tardía conserva su negocio y no recarga el salón de '
      'otra sucursal', () async {
    const businessA = 'table-exit-previous-business';
    const businessB = 'table-exit-selected-business';
    final (c, vm, server) = await salon(businessA);
    final pending = server.plan(_tableA);
    final visit = Object();
    final opening = vm.openTable(_tableA, visitId: visit);
    await pending.started.future;
    vm.abandonTableOpening(visit);

    (c.read(sessionProvider.notifier) as _Session).switchTo(businessB);
    final zones = c.read(byZoneVmProvider.notifier) as _Zones;
    await zones.load(businessB);
    pending.response.complete(_result(_orderA));
    await opening;
    await _waitUntil(() => server.released.isNotEmpty);
    await Future<void>.delayed(Duration.zero);

    expect(server.released.single.orderId, _orderA);
    expect(server.released.single.businessId, businessA);
    expect(zones.loaded, [businessB]);
    expect(c.read(byZoneVmProvider).businessId, businessB);
    expect(c.read(currentOrderProvider).order, isNull);
  });

  test('si falla la red al liberar una respuesta abandonada, guarda su '
      'liberación en la cola durable', () async {
    const businessId = 'table-exit-release-transport';
    final (c, vm, server) = await salon(businessId);
    server.releaseError = TimeoutException('La conexión se interrumpió');
    final pending = server.plan(_tableA);
    final visit = Object();

    final opening = vm.openTable(_tableA, visitId: visit);
    await pending.started.future;
    vm.abandonTableOpening(visit);
    pending.response.complete(_result(_orderA));
    await opening;
    final queued = await _waitForRelease(businessId);

    expect(server.released.map((r) => r.orderId), [_orderA]);
    expect(
      queued.where((action) => action['type'] == 'release_empty_order'),
      contains(
        allOf(
          containsPair('order_id', _orderA),
          containsPair('table_id', _tableA),
        ),
      ),
    );
    expect(c.read(currentOrderProvider).order, isNull);
  });

  test('una respuesta vacía abandonada informa el trabajo propio pendiente '
      'y conserva sus acciones', () async {
    const businessId = 'table-exit-pending-work';
    final (c, vm, server) = await salon(businessId);
    await offline.enqueueAction(
      businessId: businessId,
      action: {
        'id': 'producto-pendiente',
        'type': 'add_item',
        'order_id': _orderA,
        'origin': 'table',
        'table_id': _tableA,
        'item_id': 'tmp_cafe',
        'menu_item_id': 'cafe',
        'qty': 1,
      },
    );
    final pending = server.plan(_tableA);
    final visit = Object();

    final opening = vm.openTable(_tableA, visitId: visit);
    await pending.started.future;
    vm.abandonTableOpening(visit);
    pending.response.complete(_result(_orderA));
    await opening;
    await _waitUntil(() => server.released.isNotEmpty);

    expect(server.released.single.orderId, _orderA);
    expect(server.released.single.pending, isTrue);
    expect(
      await offline.unsettledActions(businessId),
      contains(containsPair('id', 'producto-pendiente')),
    );
    expect(c.read(currentOrderProvider).order, isNull);
  });

  test('abandonar una apertura por el proxy Hub conserva una liberación '
      'durable para la cuenta tardía', () async {
    const businessId = 'table-exit-hub-proxy';
    final (c, vm, server) = await salon(
      businessId,
      mode: TerminalMode.hubClient,
    );
    final pending = server.plan(_tableA);
    final visit = Object();

    final opening = vm.openTable(_tableA, visitId: visit);
    await pending.started.future;
    vm.abandonTableOpening(visit);
    pending.response.complete(_result(_orderA));
    await opening;
    final queued = await _waitForRelease(businessId);

    expect(server.hubOpens, [_tableA]);
    expect(server.cloudOpens, isEmpty);
    expect(server.released, isEmpty);
    expect(
      queued,
      contains(
        allOf(
          containsPair('type', 'release_empty_order'),
          containsPair('order_id', _orderA),
          containsPair('table_id', _tableA),
        ),
      ),
    );
    expect(c.read(currentOrderProvider).order, isNull);
  });

  test('salir de un borrador offline que ya recibió productos conserva la '
      'cuenta y sus acciones aunque abrió vacío', () async {
    const businessId = 'table-exit-offline-draft-with-items';
    final (c, vm, server) = await salon(businessId);
    ConnectivityService().simulateDisconnect();
    final visit = Object();
    await vm.openTable(_tableA, visitId: visit);
    final draft = c.read(currentOrderProvider);
    final orderId = draft.order!.id;
    expect(orderId, startsWith('local-order-'));
    expect(draft.items, isEmpty);

    // El cajero agrega un producto después de que la apertura guardó el
    // borrador vacío. La selección, el snapshot y la cola ya tienen trabajo.
    final updated = _result(orderId, withItems: true).bundle;
    final withItems = draft.copyWith(
      order: updated.order,
      items: updated.items,
    );
    vm.showForTest(withItems);
    await offline.saveSnapshot(
      businessId: businessId,
      slotId: _tableA,
      origin: 'table',
      tableId: _tableA,
      state: withItems,
      localOnly: true,
    );
    await offline.enqueueAction(
      businessId: businessId,
      action: {
        'id': 'producto-en-borrador',
        'type': 'add_item',
        'order_id': orderId,
        'origin': 'table',
        'table_id': _tableA,
        'item_id': 'tmp_cafe_offline',
        'menu_item_id': 'cafe',
        'qty': 1,
      },
    );

    vm.abandonTableOpening(visit);
    await Future<void>.delayed(const Duration(milliseconds: 550));

    final saved = await offline.loadSnapshot(
      businessId: businessId,
      slotId: _tableA,
    );
    expect(saved?.order?.id, orderId);
    expect(saved?.items.single.productName, 'Café');
    expect(
      await offline.unsettledActions(businessId),
      contains(containsPair('id', 'producto-en-borrador')),
    );
    expect(
      await offline.isOrderClosedLocally(
        businessId: businessId,
        orderId: orderId,
      ),
      isFalse,
    );
    expect(server.released, isEmpty);
  });
}
