// Abrir Venta Rápida/Manual nunca deja en pantalla (ni cobra) la cuenta de
// otra pantalla, retoma solo la venta de ESTE equipo por su id y la confirma
// con el servidor antes de dejarla tocar.

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
import 'package:mangopos/data/models/fiscal_models.dart';
import 'package:mangopos/data/models/sales_models.dart';
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

const _permissions = {'ventas.orden.agregar_item'};
const _cashMessage = 'Debes abrir la caja antes de iniciar una venta.';

class _Session extends SessionController {
  _Session(this.businessId);
  final String businessId;

  @override
  SessionState build() =>
      SessionState(activeBusinessId: businessId, permissions: _permissions);

  void switchTo(String id) =>
      state = SessionState(activeBusinessId: id, permissions: _permissions);
}

class _Sales extends SalesViewModel {
  _Sales({this.cashOpen = true});
  final bool cashOpen;

  @override
  CurrentOrderState build() => const CurrentOrderState();

  @override
  Future<bool> ensureCashSessionOpen() async {
    if (cashOpen) return true;
    state = state.copyWith(loading: false, error: _cashMessage);
    return false;
  }
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

  final loaded = <String>[];
  final added = <String>[];
  final retailSlots = <String>[];
  int sharedOpens = 0;
  Object? openError;
  Completer<Map<String, dynamic>>? deferredOpen;
  Map<String, dynamic> openResult = {'order_id': 'order-new'};
  final bundles = <String, _Bundle>{};
  final deferredBundles = <String, Completer<_Bundle>>{};

  /// Sesión de cada orden en el servidor (`table_sessions.origin`). Sin
  /// entrada responde como la venta rápida abierta de este equipo.
  final sessions = <String, ({String? origin, DateTime? closedAt})?>{};

  @override
  Future<({String? origin, DateTime? closedAt})?> getOrderSessionOrigin(
    String orderId, {
    required String businessId,
  }) async => sessions.containsKey(orderId)
      ? sessions[orderId]
      : (origin: 'quick', closedAt: null);

  @override
  Future<Map<String, dynamic>> openManualOrQuick({
    required String origin,
    String? customerName,
    int peopleCount = 1,
    String? businessId,
  }) async {
    sharedOpens++;
    if (deferredOpen != null) return deferredOpen!.future;
    if (openError != null) throw openError!;
    return openResult;
  }

  @override
  Future<Map<String, dynamic>> openRetailCart({
    required String slot,
    required String businessId,
    int peopleCount = 1,
  }) async {
    retailSlots.add(slot);
    return {'order_id': 'remote-$slot'};
  }

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
    return (
      itemId: 'remote-item-${added.length}',
      replayed: false,
      itemExists: true,
    );
  }

  @override
  Future<_Bundle> getOrderBundle(String orderId, {String? businessId}) async {
    loaded.add(orderId);
    final deferred = deferredBundles[orderId];
    if (deferred != null) return deferred.future;
    final bundle = bundles[orderId];
    if (bundle != null) return bundle;
    throw TimeoutException('bundle sin respuesta');
  }
}

Order _order(String id, {String status = 'open'}) => Order.fromMap({
  'id': id,
  'session_id': 'session-$id',
  'status_ext': status,
  'subtotal': 100,
  'total': 100,
  'created_at': '2026-10-09T12:00:00Z',
});

OrderItem _item(String orderId) => OrderItem.fromMap({
  'id': 'item-$orderId',
  'order_id': orderId,
  'product_name': 'Producto $orderId',
  'product_id': 'product-$orderId',
  'qty': 1,
  'unit_price': 100,
  'subtotal': 100,
  'total': 100,
  'status': 'draft',
  'created_at': '2026-10-09T12:00:00Z',
});

CurrentOrderState _sale(
  String id, {
  String origin = 'quick',
  String status = 'open',
}) => CurrentOrderState(
  origin: origin,
  order: _order(id, status: status),
  items: [_item(id)],
);

_Bundle _bundle(String id, {String status = 'open', bool withItems = true}) => (
  order: _order(id, status: status),
  items: withItems ? [_item(id)] : const <OrderItem>[],
  checks: const <OrderCheck>[],
  customerId: null,
  customerName: null,
  note: null,
);

http.Response _emptyResponse(http.BaseRequest request) => http.Response(
  request.method == 'GET' ? '[]' : 'null',
  200,
  headers: {'content-type': 'application/json'},
  request: request as http.Request,
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

Future<void> _eventually(Future<bool> Function() condition) async {
  for (var i = 0; i < 400 && !await condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(await condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final offline = OfflinePosService();
  final keys = <String, String>{};
  late OfflineQueueDb db;
  late SupabaseClient repoClient;

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
    repoClient = SupabaseClient(
      'http://localhost:54321',
      'test',
      httpClient: MockClient((request) async => _emptyResponse(request)),
    );
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient((request) async => _emptyResponse(request)),
    );
  });

  setUp(() {
    offline.setHubUploader(null);
    ConnectivityService().simulateReconnect();
  });

  tearDownAll(() async {
    await db.close();
    await repoClient.dispose();
    await Supabase.instance.dispose();
  });

  ProviderContainer container(
    String biz,
    _Repository repository, {
    bool cashOpen = true,
    bool retail = false,
  }) {
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(() => _Sales(cashOpen: cashOpen)),
        currentBusinessModelProvider.overrideWithValue(
          retail ? BusinessModel.retail : BusinessModel.restaurant,
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        byZoneVmProvider.overrideWith(_Zones.new),
        fiscalServiceProvider.overrideWithValue(_Fiscal()),
        salesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Deja la mesa A abierta en pantalla (desde su respaldo, sin red) y
  /// vuelve a conectar.
  Future<ProviderContainer> withTableA(
    String biz,
    _Repository repository, {
    bool cashOpen = true,
  }) async {
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await offline.saveSnapshot(
      businessId: biz,
      slotId: 'table-A',
      tableId: 'table-A',
      origin: 'table',
      state: _sale('order-A', origin: 'table'),
    );
    final c = container(biz, repository, cashOpen: cashOpen);
    ConnectivityService().simulateDisconnect();
    await c.read(currentOrderProvider.notifier).openTable('table-A');
    ConnectivityService().simulateReconnect();
    expect(c.read(currentOrderProvider).order?.id, 'order-A');
    expect(c.read(currentOrderProvider).origin, 'table');
    return c;
  }

  Future<void> expectTableAIntact(String biz) async {
    final saved = await offline.loadSnapshot(
      businessId: biz,
      slotId: 'table-A',
    );
    expect(saved?.order?.id, 'order-A');
    expect(saved?.items.map((i) => i.id), ['item-order-A']);
  }

  for (final origin in ['manual', 'quick']) {
    final label = origin == 'quick' ? 'Rápida' : 'Manual';
    test(
      'mesa A → Venta $label rechazada por el servidor: sin cuenta y el producto no llega a A',
      () async {
        final biz = 'table-to-$origin-business-error';
        final repository = _Repository(repoClient)
          ..openError = PostgrestException(
            message:
                'fn_open_manual_or_quick: el usuario no pertenece al negocio',
            code: 'P0001',
          );
        final c = await withTableA(biz, repository);
        final vm = c.read(currentOrderProvider.notifier);

        if (origin == 'manual') {
          await vm.ensureManualOrder();
        } else {
          await vm.ensureQuickOrder();
        }

        final visible = c.read(currentOrderProvider);
        expect(visible.order, isNull);
        expect(visible.items, isEmpty);
        expect(visible.origin, origin);
        expect(visible.loading, isFalse);
        expect(visible.error, contains('No se pudo abrir Venta $label'));
        expect(repository.sharedOpens, 1);

        await vm.addItem(
          menuItemId: 'product-new',
          productName: 'Nuevo',
          productPrice: 10,
          productTaxRate: 0,
        );
        expect(repository.added, isEmpty);
        expect(
          c.read(currentOrderProvider).error,
          'Orden no disponible. Reintenta.',
        );
        expect(c.read(currentOrderProvider).order, isNull);
        await expectTableAIntact(biz);
      },
    );
  }

  test(
    'caja cerrada al abrir Venta Manual no deja visible la mesa A',
    () async {
      const biz = 'table-to-manual-cash-closed';
      final repository = _Repository(repoClient);
      final c = await withTableA(biz, repository, cashOpen: false);
      final vm = c.read(currentOrderProvider.notifier);

      await vm.ensureManualOrder();

      final visible = c.read(currentOrderProvider);
      expect(visible.order, isNull);
      expect(visible.origin, 'manual');
      expect(visible.loading, isFalse);
      expect(visible.error, _cashMessage);
      expect(repository.sharedOpens, 0);

      await vm.addItem(
        menuItemId: 'product-new',
        productName: 'Nuevo',
        productPrice: 10,
        productTaxRate: 0,
      );
      expect(repository.added, isEmpty);
      expect(c.read(currentOrderProvider).order, isNull);
      await expectTableAIntact(biz);
    },
  );

  test(
    'recarga de la mesa A agendada antes de soltarla no entra en Venta Manual',
    () async {
      const biz = 'table-to-manual-scheduled-refresh';
      final repository = _Repository(repoClient);
      // Si la recarga llegara a correr, el servidor sí devolvería la mesa A.
      repository.bundles['order-A'] = _bundle('order-A');
      repository.deferredOpen = Completer<Map<String, dynamic>>();
      final c = await withTableA(biz, repository);
      final vm = c.read(currentOrderProvider.notifier);

      await vm.refreshOrder();
      final opening = vm.ensureManualOrder();
      // La cuenta anterior sale de pantalla en el mismo instante.
      expect(c.read(currentOrderProvider).order, isNull);
      expect(c.read(currentOrderProvider).origin, 'manual');
      expect(c.read(currentOrderProvider).loading, isTrue);

      await _waitUntil(() => repository.sharedOpens == 1);
      // Más que el debounce de la recarga (400 ms).
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(c.read(currentOrderProvider).order, isNull);
      expect(c.read(currentOrderProvider).origin, 'manual');
      expect(repository.loaded, isNot(contains('order-A')));
      expect(
        await offline.loadSnapshot(businessId: biz, slotId: 'manual'),
        isNull,
      );

      repository.deferredOpen!.completeError(StateError('rechazo'));
      await opening;
      expect(c.read(currentOrderProvider).order, isNull);
      expect(c.read(currentOrderProvider).origin, 'manual');
      expect(repository.loaded, isNot(contains('order-A')));
      expect(
        await offline.loadSnapshot(businessId: biz, slotId: 'manual'),
        isNull,
      );
      await expectTableAIntact(biz);
    },
  );

  for (final outcome in ['confirmada', 'sin red']) {
    test(
      'retomar venta del servidor ($outcome): bloqueada hasta confirmar y sin abrir otra',
      () async {
        final biz = 'resume-server-${outcome.replaceAll(' ', '-')}';
        await offline.saveSnapshot(
          businessId: biz,
          slotId: 'quick',
          origin: 'quick',
          state: _sale('order-R'),
        );
        final repository = _Repository(repoClient);
        final bundle = Completer<_Bundle>();
        repository.deferredBundles['order-R'] = bundle;
        final c = container(biz, repository);
        final vm = c.read(currentOrderProvider.notifier);

        final resuming = vm.ensureQuickOrder();
        await _waitUntil(() => repository.loaded.contains('order-R'));
        final painted = c.read(currentOrderProvider);
        expect(painted.order?.id, 'order-R');
        expect(painted.origin, 'quick');
        expect(painted.loading, isTrue);
        expect(painted.items.map((i) => i.id), ['item-order-R']);
        expect(repository.sharedOpens, 0);

        if (outcome == 'confirmada') {
          bundle.complete(_bundle('order-R'));
        } else {
          bundle.completeError(TimeoutException('red caída'));
        }
        await resuming;

        final visible = c.read(currentOrderProvider);
        expect(visible.loading, isFalse);
        expect(visible.order?.id, 'order-R');
        expect(visible.origin, 'quick');
        expect(visible.items.map((i) => i.id), ['item-order-R']);
        expect(repository.sharedOpens, 0);
      },
    );
  }

  test('borrador local retomado se usa de una vez, sin servidor', () async {
    const biz = 'resume-local-draft-online';
    await offline.saveSnapshot(
      businessId: biz,
      slotId: 'manual',
      origin: 'manual',
      state: _sale('local-order-L', origin: 'manual', status: 'draft'),
      localOnly: true,
    );
    final repository = _Repository(repoClient);
    final c = container(biz, repository);

    await c.read(currentOrderProvider.notifier).ensureManualOrder();

    final visible = c.read(currentOrderProvider);
    expect(visible.order?.id, 'local-order-L');
    expect(visible.origin, 'manual');
    expect(visible.loading, isFalse);
    expect(repository.loaded, isEmpty);
    expect(repository.sharedOpens, 0);
  });

  for (final reason in ['paid', 'void', 'inaccesible']) {
    test(
      'respaldo que ya no sirve en el servidor ($reason) abre una venta nueva',
      () async {
        final biz = 'resume-not-reusable-$reason';
        await offline.saveSnapshot(
          businessId: biz,
          slotId: 'quick',
          origin: 'quick',
          state: _sale('order-old'),
        );
        final repository = _Repository(repoClient);
        repository.bundles['order-old'] = reason == 'inaccesible'
            ? (
                order: null,
                items: const <OrderItem>[],
                checks: const <OrderCheck>[],
                customerId: null,
                customerName: null,
                note: null,
              )
            : _bundle('order-old', status: reason);
        repository.bundles['order-new'] = _bundle(
          'order-new',
          withItems: false,
        );
        final c = container(biz, repository);

        await c.read(currentOrderProvider.notifier).ensureQuickOrder();

        final visible = c.read(currentOrderProvider);
        expect(visible.order?.id, 'order-new');
        expect(visible.origin, 'quick');
        expect(visible.loading, isFalse);
        expect(visible.error, isNull);
        expect(repository.sharedOpens, 1);
        expect(repository.loaded, ['order-old', 'order-new']);
        expect(
          (await offline.loadSnapshot(
            businessId: biz,
            slotId: 'quick',
          ))?.order?.id,
          'order-new',
        );
      },
    );
  }

  test(
    'dos aperturas seguidas de la misma pantalla piden una sola venta',
    () async {
      const biz = 'join-in-flight-quick-open';
      final repository = _Repository(repoClient);
      repository.deferredOpen = Completer<Map<String, dynamic>>();
      repository.bundles['order-new'] = _bundle('order-new', withItems: false);
      final c = container(biz, repository);
      final vm = c.read(currentOrderProvider.notifier);

      final first = vm.ensureQuickOrder();
      await _waitUntil(() => repository.sharedOpens == 1);
      final second = vm.ensureQuickOrder();
      repository.deferredOpen!.complete({'order_id': 'order-new'});
      await Future.wait([first, second]);

      expect(repository.sharedOpens, 1);
      expect(c.read(currentOrderProvider).order?.id, 'order-new');
      expect(c.read(currentOrderProvider).loading, isFalse);
    },
  );

  test(
    'venta cobrada en línea no se retoma sin red aunque la app reinicie',
    () async {
      const biz = 'paid-online-closing-marker';
      await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
      await offline.saveSnapshot(
        businessId: biz,
        slotId: 'quick',
        origin: 'quick',
        state: _sale('order-Q'),
      );
      final first = container(biz, _Repository(repoClient));
      first.read(currentOrderProvider.notifier).markOrderClosing('order-Q');
      await _eventually(
        () => offline.isOrderClosedLocally(businessId: biz, orderId: 'order-Q'),
      );
      expect(
        await offline.loadSnapshot(businessId: biz, slotId: 'quick'),
        isNull,
      );

      // Otra instancia del viewmodel (reinicio): ya no recuerda la venta en
      // cierre, solo lo que quedó guardado en el equipo.
      final repository = _Repository(repoClient);
      final restarted = container(biz, repository);
      ConnectivityService().simulateDisconnect();
      await restarted.read(currentOrderProvider.notifier).ensureQuickOrder();

      final visible = restarted.read(currentOrderProvider);
      expect(visible.order?.id, startsWith('local-order-'));
      expect(visible.items, isEmpty);
      expect(repository.sharedOpens, 0);
    },
  );

  for (final switchBusiness in [false, true]) {
    test(
      switchBusiness
          ? 'cliente elegido para la venta siguiente no pasa a otra sucursal'
          : 'cliente elegido para la venta siguiente se aplica en la misma sucursal',
      () async {
        final biz = 'next-customer-switch-$switchBusiness';
        final c = container(biz, _Repository(repoClient));
        final vm = c.read(currentOrderProvider.notifier);

        final queued = await vm.assignCustomerToCurrentOrder(
          customerId: 'customer-1',
          customerName: 'Ana',
          nextOrderOrigin: 'quick',
        );
        expect(queued, isNull);
        if (switchBusiness) {
          (c.read(sessionProvider.notifier) as _Session).switchTo('$biz-2');
        }
        ConnectivityService().simulateDisconnect();
        await vm.ensureQuickOrder();

        final visible = c.read(currentOrderProvider);
        expect(visible.order?.id, startsWith('local-order-'));
        expect(visible.customerId, switchBusiness ? isNull : 'customer-1');
      },
    );
  }

  test(
    'retail: carrito cobrado sigue por carritos, nunca abre la venta rápida general',
    () async {
      const biz = 'retail-paid-cart-restart';
      await offline.saveSnapshot(
        businessId: biz,
        slotId: 'quick-one',
        origin: 'quick',
        state: _sale('order-P'),
      );
      final repository = _Repository(repoClient);
      repository.bundles['order-P'] = _bundle('order-P', status: 'paid');
      final c = container(biz, repository, retail: true);
      c.read(retailCartsProvider.notifier).replaceAll([
        RetailCart(slotId: 'quick-one', number: 1, orderId: 'order-P'),
      ], 'quick-one');
      final vm = c.read(currentOrderProvider.notifier);
      await vm.switchRetailCart('quick-one');
      expect(c.read(currentOrderProvider).order?.status, 'paid');

      await vm.addItem(
        menuItemId: 'product-new',
        productName: 'Nuevo',
        productPrice: 10,
        productTaxRate: 0,
      );

      expect(repository.sharedOpens, 0);
      expect(repository.added, isEmpty);
      expect(repository.retailSlots, hasLength(1));
      expect(repository.retailSlots.single, startsWith('quick-'));
      expect(
        c.read(retailCartsProvider).carts.map((cart) => cart.slotId),
        isNot(contains('quick-one')),
      );
    },
  );
}
