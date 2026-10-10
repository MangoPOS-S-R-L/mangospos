// Autor de cada producto (order_items.created_by_employee_id): el mesero del
// PIN capturado al tocar; sin PIN, el dueño de la mesa de la orden CAPTURADA;
// sin dueño (o en Venta Rápida/Manual), el empleado del usuario autenticado
// del negocio capturado. El empleado del cajero nunca entra como autor de lo
// que agrega en la mesa de un mesero, y la caché de ese empleado no cruza
// sucursales ni usuarios.

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/multimesero/active_waiter_provider.dart';
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

const _permissions = {
  'ventas.orden.agregar_item',
  'ventas.orden.editar_item',
};

class _Session extends SessionController {
  _Session(this.businessId, {this.role = PosRole.cajero});
  final String businessId;
  final PosRole role;

  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    userId: 'u-cashier',
    activeBusinessId: businessId,
    activeRole: role,
    permissions: _permissions,
  );

  void debugSetBusiness(String id) =>
      state = state.copyWith(activeBusinessId: id);

  void debugSetUser(String id) => state = state.copyWith(userId: id);
}

// build() reemplazado (sin timers ni Realtime), pero registra los MISMOS
// listeners de identidad que build() de producción.
class _Sales extends SalesViewModel {
  _Sales(this.initial);
  final CurrentOrderState initial;

  @override
  CurrentOrderState build() {
    listenAuthEmployeeIdentity();
    return initial;
  }

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

class _HubClientMode extends StateNotifier<TerminalMode>
    implements HubModeController {
  _HubClientMode() : super(TerminalMode.hubClient);
  @override
  String? get reachableHubUrl => 'http://hub.local';
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

typedef _AddResult = ({String itemId, bool replayed, bool itemExists});

class _Repository extends SalesRepository {
  _Repository(super.client);

  final started = <String, Completer<void>>{};
  final additions = <String, Completer<_AddResult>>{};
  final deletions = <String, Completer<void>>{};
  final addCalls = <({String orderId, String? createdBy})>[];
  final hubCalls = <({String orderId, String? employeeId, int lookups})>[];
  final openers = <String, String?>{};
  final openerErrors = <String>{};
  final pendingOpeners = <String, Completer<String?>>{};
  final openerLookups = <String>[];
  final currentEmployees = <String, String?>{};
  final pendingCurrent = <String, Completer<String?>>{};
  final currentEmployeeLookups = <String>[];
  final stamps = <(String, String)>[];
  final removals = <(String, String?)>[];
  final events = <String>[];
  final loaded = <String>[];

  int get attributionCalls =>
      openerLookups.length + currentEmployeeLookups.length + stamps.length;

  Future<void> waitFor(String operation) =>
      started.putIfAbsent(operation, Completer<void>.new).future;
  void start(String operation) {
    final c = started.putIfAbsent(operation, Completer<void>.new);
    if (!c.isCompleted) c.complete();
  }

  void clearLog() {
    openerLookups.clear();
    currentEmployeeLookups.clear();
    stamps.clear();
    removals.clear();
    events.clear();
  }

  @override
  Future<_AddResult> addItemFromMenuIdempotent({
    required String clientOpId,
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
    String? createdByEmployeeId,
  }) {
    addCalls.add((orderId: orderId, createdBy: createdByEmployeeId));
    events.add('add');
    final result = additions.putIfAbsent(menuItemId, Completer<_AddResult>.new);
    start('add-$menuItemId');
    return result.future;
  }

  @override
  Future<String?> addItemFromMenuViaHub({
    required String hubBaseUrl,
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
    List<Map<String, dynamic>> modifiers = const [],
    String? employeeId,
    String? clientOpId,
  }) async {
    hubCalls.add((
      orderId: orderId,
      employeeId: employeeId,
      lookups: attributionCalls,
    ));
    return 'real-hub';
  }

  @override
  Future<void> addOrderItemModifiers({
    required String itemId,
    required List<Map<String, dynamic>> modifiers,
  }) async {
    events.add('modifiers');
  }

  @override
  Future<String?> fetchOrderOpenerEmployeeId(String orderId) {
    openerLookups.add(orderId);
    events.add('opener');
    if (openerErrors.contains(orderId)) {
      return Future.error(StateError('opener rechazado'));
    }
    final pending = pendingOpeners[orderId];
    if (pending != null) return pending.future;
    return Future.value(openers[orderId]);
  }

  @override
  Future<String?> fetchCurrentEmployeeId(String businessId) {
    currentEmployeeLookups.add(businessId);
    final pending = pendingCurrent.remove(businessId);
    if (pending != null) return pending.future;
    return Future.value(currentEmployees[businessId]);
  }

  @override
  Future<void> setItemCreatedByEmployee({
    required String itemId,
    required String employeeId,
  }) async {
    stamps.add((itemId, employeeId));
    events.add('stamp');
  }

  @override
  Future<void> noteItemRemoval({
    required String itemId,
    String? reason,
    String? employeeId,
    String? reasonCode,
    bool? isWaste,
  }) async {
    removals.add((itemId, employeeId));
  }

  @override
  Future<void> deleteItem({required String itemId}) {
    final result = deletions.putIfAbsent(itemId, Completer<void>.new);
    start('delete-$itemId');
    return result.future;
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
    throw TimeoutException('bundle unavailable');
  }
}

CurrentOrderState _sale(String id, {String origin = 'table'}) =>
    CurrentOrderState(
      origin: origin,
      order: Order.fromMap({
        'id': 'order-$id',
        'session_id': 'session-$id',
        'status_ext': 'open',
        'subtotal': 100,
        'total': 100,
        'created_at': '2026-10-09T12:00:00Z',
      }),
      items: [
        OrderItem.fromMap({
          'id': 'item-$id',
          'order_id': 'order-$id',
          'product_name': 'Producto $id',
          'product_id': 'product-$id',
          'qty': 1,
          'unit_price': 100,
          'subtotal': 100,
          'total': 100,
          'status': 'draft',
          'created_at': '2026-10-09T12:00:00Z',
        }),
      ],
    );

const _added = (itemId: 'real-new', replayed: false, itemExists: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final offline = OfflinePosService();
  final secureStore = <String, String>{};
  // Llamadas que el viewmodel haga DIRECTO a Supabase (sin repositorio).
  final directPaths = <String>[];
  final directRequests = <({String path, String body})>[];
  late OfflineQueueDb db;
  late SupabaseClient client;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            if (call.method == 'write') {
              secureStore[args['key'] as String] = args['value'] as String;
            }
            if (call.method == 'read') return secureStore[args['key']];
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
        directPaths.add(request.url.path);
        directRequests.add((path: request.url.path, body: request.body));
        return http.Response(
          request.method == 'GET' ? '[]' : 'null',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
  });

  setUp(() {
    directPaths.clear();
    directRequests.clear();
    offline.setHubUploader(null);
    ConnectivityService().simulateReconnect();
  });

  tearDownAll(() async {
    await db.close();
    await client.dispose();
    await Supabase.instance.dispose();
  });

  bool directAttribution() => directPaths.any(
    (p) =>
        p.contains('fn_order_opener_employee_id') ||
        p.contains('fn_current_employee_id') ||
        p.contains('order_items'),
  );

  Future<ProviderContainer> prepare(
    String biz,
    _Repository repository, {
    CurrentOrderState? initial,
    PosRole role = PosRole.cajero,
    bool hub = false,
  }) async {
    for (final b in [biz, '$biz-2']) {
      await PosLookupOfflineCache().saveBusinessTaxes(b, []);
    }
    await offline.saveSnapshot(
      businessId: biz,
      slotId: 'table-B',
      tableId: 'table-B',
      origin: 'table',
      state: _sale('B'),
    );
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz, role: role)),
        currentOrderProvider.overrideWith(() => _Sales(initial ?? _sale('A'))),
        hubModeProvider.overrideWith(
          (ref) => hub ? _HubClientMode() : _CloudHub(),
        ),
        byZoneVmProvider.overrideWith(_Zones.new),
        fiscalServiceProvider.overrideWithValue(_Fiscal()),
        salesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    container.read(currentOrderProvider);
    return container;
  }

  _Session sessionOf(ProviderContainer c) =>
      c.read(sessionProvider.notifier) as _Session;

  void pin(ProviderContainer c, String biz, {String id = 'emp-pin'}) =>
      c
          .read(activeWaiterProvider.notifier)
          .setActive(
            ActiveWaiter(
              employeeId: id,
              firstName: 'Ana',
              businessId: biz,
              validatedAt: DateTime.now(),
            ),
          );

  Future<void> addNew(SalesViewModel vm, {List<SelectedModifierInput>? mods}) =>
      vm.addItem(
        menuItemId: 'new',
        productName: 'Nuevo',
        productPrice: 25,
        productTaxRate: 0,
        selectedModifiers: mods ?? const [],
      );

  OrderItem? optimistic(ProviderContainer c) => c
      .read(currentOrderProvider)
      .items
      .where((i) => i.id.startsWith('tmp_'))
      .firstOrNull;

  // Decisión del dueño (2026-10-10): lo que agrega el cajero (entra con su
  // usuario, sin PIN) se le acredita a él aunque la mesa sea de un mesero.
  // Antes iba al dueño de la mesa.
  test('cajero sin PIN en la mesa de un mesero: el ítem va al cajero', () async {
    const biz = 'attr-cashier-opener';
    final repo = _Repository(client)
      ..currentEmployees[biz] = 'emp-cashier'
      ..openers['order-A'] = 'emp-opener-A';
    final c = await prepare(biz, repo);
    final vm = c.read(currentOrderProvider.notifier);
    await vm.noteItemRemoval('item-A');
    expect(repo.removals.single, ('item-A', 'emp-cashier'));
    repo.clearLog();

    final adding = addNew(vm);
    await repo.waitFor('add-new');
    repo.additions['new']!.complete(_added);
    await adding;

    expect(repo.openerLookups, isEmpty, reason: 'el dueño no se consulta');
    expect(repo.stamps, [('real-new', 'emp-cashier')]);
    expect(directAttribution(), isFalse);
  });

  test('administrador y supervisor sin PIN: también se les acredita', () async {
    for (final role in [PosRole.administrador, PosRole.supervisor]) {
      final biz = 'attr-${role.name}';
      final repo = _Repository(client)
        ..currentEmployees[biz] = 'emp-${role.name}'
        ..openers['order-A'] = 'emp-opener-A';
      final c = await prepare(biz, repo, role: role);
      final vm = c.read(currentOrderProvider.notifier);
      final adding = addNew(vm);
      await repo.waitFor('add-new');
      repo.additions['new']!.complete(_added);
      await adding;

      expect(repo.openerLookups, isEmpty);
      expect(repo.stamps, [('real-new', 'emp-${role.name}')]);
    }
  });

  test('mesero con PIN: el ítem va al PIN en la misma alta', () async {
    const biz = 'attr-pin';
    final repo = _Repository(client)..openers['order-A'] = 'emp-opener-A';
    final c = await prepare(biz, repo, role: PosRole.mesero);
    pin(c, biz);
    final vm = c.read(currentOrderProvider.notifier);
    final adding = addNew(vm);
    await repo.waitFor('add-new');
    expect(optimistic(c)!.createdByEmployeeId, 'emp-pin');
    expect(optimistic(c)!.createdByEmployeeName, 'Ana');
    repo.additions['new']!.complete(_added);
    await adding;

    expect(repo.addCalls.single.createdBy, 'emp-pin');
    expect(repo.openerLookups, isEmpty);
    expect(repo.stamps, isEmpty);
  });

  test('un PIN que aparece después del toque no cambia el autor', () async {
    const biz = 'attr-late-pin';
    final repo = _Repository(client)..openers['order-A'] = 'emp-opener-A';
    final c = await prepare(biz, repo, role: PosRole.mesero);
    final vm = c.read(currentOrderProvider.notifier);
    final adding = addNew(vm);
    await repo.waitFor('add-new');
    pin(c, biz, id: 'emp-late');
    repo.additions['new']!.complete(_added);
    await adding;

    expect(repo.addCalls.single.createdBy, isNull);
    expect(repo.stamps, [('real-new', 'emp-opener-A')]);
  });

  test('navegar a otra cuenta durante el alta: el autor sale de la orden '
      'capturada', () async {
    const biz = 'attr-navigate';
    final repo = _Repository(client)
      ..currentEmployees[biz] = 'emp-cashier'
      ..openers['order-A'] = 'emp-opener-A'
      ..openers['order-B'] = 'emp-opener-B';
    final c = await prepare(biz, repo, role: PosRole.mesero);
    final vm = c.read(currentOrderProvider.notifier);
    await vm.noteItemRemoval('item-A');
    repo.clearLog();

    final adding = addNew(vm);
    await repo.waitFor('add-new');
    ConnectivityService().simulateDisconnect();
    await vm.openTable('table-B');
    ConnectivityService().simulateReconnect();
    final before = c.read(currentOrderProvider);
    expect(before.order?.id, 'order-B');
    repo.additions['new']!.complete(_added);
    await adding;

    expect(repo.openerLookups, ['order-A']);
    expect(repo.stamps, [('real-new', 'emp-opener-A')]);
    expect(c.read(currentOrderProvider).order, before.order);
    expect(c.read(currentOrderProvider).items, before.items);
    expect(repo.loaded, isEmpty);
  });

  test('sin dueño de mesa: cae al empleado del negocio capturado aunque '
      'cambie la sucursal', () async {
    const biz = 'attr-no-opener';
    const biz2 = '$biz-2';
    final repo = _Repository(client)
      ..openers['order-A'] = null
      ..currentEmployees[biz] = 'emp-biz1'
      ..currentEmployees[biz2] = 'emp-biz2';
    final c = await prepare(biz, repo);
    final vm = c.read(currentOrderProvider.notifier);
    final adding = addNew(vm);
    await repo.waitFor('add-new');
    sessionOf(c).debugSetBusiness(biz2);
    repo.additions['new']!.complete(_added);
    await adding;

    expect(repo.currentEmployeeLookups, [biz]);
    expect(repo.stamps, [('real-new', 'emp-biz1')]);
  });

  test('Venta Rápida: sin consultar dueño, se acredita al usuario '
      'autenticado', () async {
    const biz = 'attr-quick';
    final repo = _Repository(client)
      ..currentEmployees[biz] = 'emp-cashier'
      ..openers['order-A'] = 'emp-otro-cajero';
    final c = await prepare(biz, repo, initial: _sale('A', origin: 'quick'));
    final vm = c.read(currentOrderProvider.notifier);
    final adding = addNew(vm);
    await repo.waitFor('add-new');
    repo.additions['new']!.complete(_added);
    await adding;

    expect(repo.openerLookups, isEmpty);
    expect(repo.stamps, [('real-new', 'emp-cashier')]);
  });

  // Decisión del dueño (fase 4): sin saber quién abrió la mesa (en prod
  // `fn_order_opener_employee_id` no existe), el ítem va al empleado del
  // usuario conectado, como en HEAD. Antes esta prueba exigía dejarlo null.
  test('la consulta del dueño falla: el ítem va al empleado del usuario '
      'conectado', () async {
    const biz = 'attr-opener-error';
    final repo = _Repository(client)
      ..currentEmployees[biz] = 'emp-cashier'
      ..openerErrors.add('order-A');
    final c = await prepare(biz, repo, role: PosRole.mesero);
    final vm = c.read(currentOrderProvider.notifier);
    await vm.noteItemRemoval('item-A');
    repo.clearLog();
    final adding = addNew(vm);
    await repo.waitFor('add-new');
    repo.additions['new']!.complete(_added);
    await adding;

    expect(repo.openerLookups, ['order-A']);
    expect(repo.stamps, [('real-new', 'emp-cashier')]);
    // El ítem quedó guardado: nada se encola ni se revierte por el autor.
    expect(await offline.unsettledActions(biz), isEmpty);
    expect(
      c.read(currentOrderProvider).items.map((i) => i.productName),
      contains('Nuevo'),
    );
  });

  test('la consulta del dueño falla con la caché fría: también va al '
      'empleado del negocio capturado', () async {
    const biz = 'attr-opener-error-cold';
    final repo = _Repository(client)
      ..currentEmployees[biz] = 'emp-cashier'
      ..openerErrors.add('order-A');
    final c = await prepare(biz, repo, role: PosRole.mesero);
    final vm = c.read(currentOrderProvider.notifier);
    final adding = addNew(vm);
    await repo.waitFor('add-new');
    repo.additions['new']!.complete(_added);
    await adding;

    expect(repo.openerLookups, ['order-A']);
    expect(repo.currentEmployeeLookups, [biz]);
    expect(repo.stamps, [('real-new', 'emp-cashier')]);
  });

  test('cajero sin PIN en la mesa de un mesero: el autor es el cajero y un '
      'retiro sin red después también lo lleva', () async {
    const biz = 'attr-warm-on-add';
    final repo = _Repository(client)
      ..currentEmployees[biz] = 'emp-cashier'
      ..openers['order-A'] = 'emp-opener-A';
    final c = await prepare(biz, repo);
    final vm = c.read(currentOrderProvider.notifier);
    // Caché fría: ningún retiro en línea ni venta rápida antes del alta.
    final adding = addNew(vm);
    await repo.waitFor('add-new');
    repo.additions['new']!.complete(_added);
    await adding;
    for (var i = 0; i < 100 && repo.currentEmployeeLookups.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await Future<void>.delayed(Duration.zero);

    // El cajero firma el ítem (decisión del dueño, 2026-10-10): la comanda
    // de lo que él agrega sale a su nombre.
    expect(repo.stamps, [('real-new', 'emp-cashier')]);

    ConnectivityService().simulateDisconnect();
    final deleting = vm.deleteItem('item-A');
    await repo.waitFor('delete-item-A');
    repo.deletions['item-A']!.completeError(TimeoutException('no WAN'));
    expect(await deleting, isTrue);

    final queued = (await offline.unsettledActions(
      biz,
    )).where((a) => a['type'] == 'delete_item').single;
    expect(queued['employee_id'], 'emp-cashier');
  });

  test('quitar impuestos: excluded_by es quien lo hace (cajero o PIN), nunca '
      'el dueño de la mesa', () async {
    for (final withPin in [false, true]) {
      final biz = 'attr-excluded-taxes-$withPin';
      final repo = _Repository(client)
        ..currentEmployees[biz] = 'emp-cashier'
        ..openers['order-A'] = 'emp-opener-A';
      final c = await prepare(
        biz,
        repo,
        role: withPin ? PosRole.mesero : PosRole.cajero,
      );
      if (withPin) pin(c, biz);
      final vm = c.read(currentOrderProvider.notifier);
      directRequests.clear();

      final error = await vm.setExcludedTaxes({'tax-itbis'});

      expect(error, isNull);
      final rpc = directRequests
          .where((r) => r.path.endsWith('/fn_set_order_excluded_taxes'))
          .single;
      final body = jsonDecode(rpc.body) as Map<String, dynamic>;
      expect(body['p_order_id'], 'order-A');
      expect(body['p_tax_ids'], ['tax-itbis']);
      expect(body['p_employee_id'], withPin ? 'emp-pin' : 'emp-cashier');
      expect(repo.openerLookups, isEmpty);
    }
  });

  test('los extras se guardan antes del autor y un dueño colgado no los '
      'frena', () async {
    const biz = 'attr-modifiers-first';
    final repo = _Repository(client)
      ..pendingOpeners['order-A'] = Completer<String?>();
    final c = await prepare(biz, repo, role: PosRole.mesero);
    final vm = c.read(currentOrderProvider.notifier);
    final adding = addNew(
      vm,
      mods: const [SelectedModifierInput(name: 'Queso', price: 10)],
    );
    await repo.waitFor('add-new');
    repo.additions['new']!.complete(_added);
    for (var i = 0; i < 100 && !repo.events.contains('opener'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(repo.events, ['add', 'modifiers', 'opener']);
    repo.pendingOpeners['order-A']!.complete('emp-opener-A');
    await adding;
    expect(repo.events, ['add', 'modifiers', 'opener', 'stamp']);
    expect(repo.stamps, [('real-new', 'emp-opener-A')]);
  });

  test('alta offline del cajero no lleva su id en el respaldo; la del PIN '
      'sí', () async {
    for (final withPin in [false, true]) {
      final biz = 'attr-offline-$withPin';
      final repo = _Repository(client)..currentEmployees[biz] = 'emp-cashier';
      final c = await prepare(
        biz,
        repo,
        role: withPin ? PosRole.mesero : PosRole.cajero,
      );
      if (withPin) pin(c, biz);
      final vm = c.read(currentOrderProvider.notifier);
      await vm.noteItemRemoval('item-A');
      final adding = addNew(vm);
      await repo.waitFor('add-new');
      repo.additions['new']!.completeError(TimeoutException('lost response'));
      await adding;

      final queued = (await offline.unsettledActions(biz)).single;
      expect(queued['type'], 'add_item');
      final snapshot = Map<String, dynamic>.from(queued['item_snapshot'] as Map);
      expect(snapshot['created_by_employee_id'], withPin ? 'emp-pin' : null);
    }
  });

  test('modo Hub: ninguna consulta directa a Supabase antes del proxy y el '
      'proxy nunca recibe al cajero', () async {
    for (final withPin in [false, true]) {
      final biz = 'attr-hub-$withPin';
      final repo = _Repository(client)
        ..currentEmployees[biz] = 'emp-cashier'
        ..openers['order-A'] = 'emp-opener-A';
      final c = await prepare(
        biz,
        repo,
        hub: true,
        role: withPin ? PosRole.mesero : PosRole.cajero,
      );
      if (withPin) pin(c, biz);
      final vm = c.read(currentOrderProvider.notifier);
      await vm.noteItemRemoval('item-A');
      repo.clearLog();
      directPaths.clear();

      await addNew(vm);

      final call = repo.hubCalls.single;
      expect(call.orderId, 'order-A');
      expect(call.employeeId, withPin ? 'emp-pin' : isNull);
      expect(call.lookups, 0);
      expect(repo.attributionCalls, 0);
      expect(directAttribution(), isFalse);
      expect(
        c.read(currentOrderProvider).items.map((i) => i.id),
        contains('real-hub'),
      );
    }
  });

  test('ida y vuelta de sucursal limpia la caché (listener real) y cada '
      'negocio usa su empleado', () async {
    const biz = 'attr-business-switch';
    const biz2 = '$biz-2';
    final repo = _Repository(client)
      ..currentEmployees[biz] = 'emp-biz1'
      ..currentEmployees[biz2] = 'emp-biz2';
    final c = await prepare(biz, repo);
    final vm = c.read(currentOrderProvider.notifier);
    await vm.noteItemRemoval('r1');
    // Sin consultar en medio: solo el listener puede haber vaciado la caché.
    sessionOf(c).debugSetBusiness(biz2);
    sessionOf(c).debugSetBusiness(biz);
    await vm.noteItemRemoval('r2');
    sessionOf(c).debugSetBusiness(biz2);
    await vm.noteItemRemoval('r3');

    expect(repo.currentEmployeeLookups, [biz, biz, biz2]);
    expect(repo.removals, [
      ('r1', 'emp-biz1'),
      ('r2', 'emp-biz1'),
      ('r3', 'emp-biz2'),
    ]);
  });

  test('retiro offline tras cambiar de sucursal no lleva el empleado de la '
      'sucursal anterior', () async {
    const biz = 'attr-offline-delete-switch';
    const biz2 = '$biz-2';
    final repo = _Repository(client)..currentEmployees[biz] = 'emp-biz1';
    final c = await prepare(biz, repo);
    final vm = c.read(currentOrderProvider.notifier) as _Sales;
    await vm.noteItemRemoval('r1');
    sessionOf(c).debugSetBusiness(biz2);
    vm.showForTest(_sale('C', origin: 'quick'));
    final deleting = vm.deleteItem('item-C');
    await repo.waitFor('delete-item-C');
    repo.deletions['item-C']!.completeError(TimeoutException('no WAN'));
    expect(await deleting, isTrue);

    final queued = (await offline.unsettledActions(biz2)).single;
    expect(queued['type'], 'delete_item');
    expect(queued['employee_id'], isNull);
  });

  test('borrado en línea: el retiro se anota con el negocio capturado aunque '
      'cambie la sucursal antes de que responda', () async {
    const biz = 'attr-delete-captured';
    const biz2 = '$biz-2';
    final repo = _Repository(client)
      ..currentEmployees[biz] = 'emp-biz1'
      ..currentEmployees[biz2] = 'emp-biz2';
    final c = await prepare(biz, repo);
    final vm = c.read(currentOrderProvider.notifier);
    final deleting = vm.deleteItem('item-A');
    await repo.waitFor('delete-item-A');
    sessionOf(c).debugSetBusiness(biz2);
    repo.deletions['item-A']!.complete();
    expect(await deleting, isTrue);
    for (var i = 0; i < 100 && repo.removals.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }

    expect(repo.currentEmployeeLookups, [biz]);
    expect(repo.removals, [('item-A', 'emp-biz1')]);
  });

  test('cambio de usuario limpia la caché (listener real) y no reutiliza al '
      'empleado anterior', () async {
    const biz = 'attr-user-switch';
    final repo = _Repository(client)..currentEmployees[biz] = 'emp-u1';
    final c = await prepare(biz, repo);
    final vm = c.read(currentOrderProvider.notifier);
    await vm.noteItemRemoval('r1');
    sessionOf(c).debugSetUser('u2');
    sessionOf(c).debugSetUser('u-cashier');
    await vm.noteItemRemoval('r2');
    expect(repo.currentEmployeeLookups, [biz, biz]);

    sessionOf(c).debugSetUser('u2');
    repo.currentEmployees[biz] = 'emp-u2';
    await vm.noteItemRemoval('r3');
    expect(repo.removals.last, ('r3', 'emp-u2'));
  });

  test('si otro usuario entra durante el sello, su empleado no firma el ítem '
      'del anterior ni se queda en caché', () async {
    const biz = 'attr-user-in-flight';
    final pending = Completer<String?>();
    final repo = _Repository(client)..pendingCurrent[biz] = pending;
    final c = await prepare(biz, repo, initial: _sale('A', origin: 'quick'));
    final vm = c.read(currentOrderProvider.notifier);
    final adding = addNew(vm);
    await repo.waitFor('add-new');
    repo.additions['new']!.complete(_added);
    for (var i = 0; i < 100 && repo.currentEmployeeLookups.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    sessionOf(c).debugSetUser('u2');
    pending.complete('emp-u2');
    await adding;
    expect(repo.stamps, isEmpty);

    repo.currentEmployees[biz] = 'emp-u2';
    await vm.noteItemRemoval('r1');
    expect(repo.currentEmployeeLookups, [biz, biz]);
    expect(repo.removals.single, ('r1', 'emp-u2'));
  });
}
