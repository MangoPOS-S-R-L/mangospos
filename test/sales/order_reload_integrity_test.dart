// Recargas de la MISMA cuenta (`_loadOrderDetail`): nunca se aplica un
// respaldo a medias sobre la pantalla (precuenta), un "no existe" del servidor
// no queda como error fijo, una operación fallida o muerta en la cola no
// bloquea la lectura para siempre (si otro equipo cerró la cuenta, se adopta
// el cierre) y un alta que cae a la cola durante la lectura no se pierde.
// Un cierre solo se adopta si es definitivo: una anulada sin cobro con altas
// aún por subir (el barrendero de mesas vacías) la resucita el servidor al
// subirlas. Un cierre adoptado no queda fijo si el servidor reabre la cuenta,
// y la cola no se lee (ni descifra) completa dos veces por recarga.

import 'dart:async';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
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
import 'package:mangopos/data/models/order_item_tax_line.dart';
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

typedef _Bundle = ({
  Order? order,
  List<OrderItem> items,
  List<OrderCheck> checks,
  String? customerId,
  String? customerName,
  String? note,
});

/// Cuenta las lecturas COMPLETAS de la cola (filas con su payload cifrado)
/// por negocio. El conteo por estado (sin payload) no cuenta.
class _QueueReads extends QueryInterceptor {
  final counts = <String, int>{};

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('FROM "queue_actions"') &&
        !statement.contains('COUNT(') &&
        args.length == 1 &&
        args.single is String) {
      final businessId = args.single as String;
      counts[businessId] = (counts[businessId] ?? 0) + 1;
    }
    return super.runSelect(executor, statement, args);
  }
}

class _Repository extends SalesRepository {
  _Repository(super.client);

  final loaded = <String>[];

  /// `includeModifiers` de cada lectura de respaldo de ítems.
  final itemReads = <bool>[];

  // Bundle (fn_get_order_bundle).
  Object? bundleError;
  _Bundle? bundle;
  final bundles = <String, _Bundle>{};
  Completer<_Bundle>? deferredBundle;

  // Lecturas de respaldo.
  Order? fallbackOrder;
  List<OrderItem> fallbackItems = const [];
  Object? fallbackItemsError;
  Object? fallbackCustomerError;

  // Venta rápida/manual: sesión de la orden retomada y aperturas nuevas.
  ({String? origin, DateTime? closedAt})? session = (
    origin: 'quick',
    closedAt: null,
  );
  int opens = 0;

  @override
  Future<_Bundle> getOrderBundle(String orderId, {String? businessId}) async {
    loaded.add(orderId);
    if (deferredBundle != null) return deferredBundle!.future;
    if (bundleError != null) throw bundleError!;
    final byId = bundles[orderId];
    if (byId != null) return byId;
    if (bundle != null) return bundle!;
    throw TimeoutException('bundle sin respuesta');
  }

  @override
  Future<({String? origin, DateTime? closedAt})?> getOrderSessionOrigin(
    String orderId, {
    required String businessId,
  }) async => session;

  @override
  Future<Map<String, dynamic>> openManualOrQuick({
    required String origin,
    String? customerName,
    int peopleCount = 1,
    String? businessId,
  }) async {
    opens++;
    return {'order_id': 'order-new'};
  }

  @override
  Future<Order?> getOrder(String orderId, {String? businessId}) async =>
      fallbackOrder;

  @override
  Future<List<OrderItem>> getOrderItems(
    String orderId, {
    bool includeModifiers = true,
    int limit = 500,
    bool onlyOpen = false,
    String? businessId,
  }) async {
    itemReads.add(includeModifiers);
    if (fallbackItemsError != null) throw fallbackItemsError!;
    // Igual que el repositorio real: sin includeModifiers no hay extras ni
    // líneas de impuesto.
    if (!includeModifiers) {
      return fallbackItems
          .map(
            (i) => i.copyWith(
              modifiers: const <OrderItemModifier>[],
              taxLines: const <OrderItemTaxLine>[],
            ),
          )
          .toList(growable: false);
    }
    return fallbackItems;
  }

  @override
  Future<List<OrderCheck>> getOrderChecks(
    String orderId, {
    String? businessId,
  }) async => const <OrderCheck>[];

  @override
  Future<({String? customerId, String? customerName, String? note})>
  getSessionCustomer(String sessionId, {String? businessId}) async {
    if (fallbackCustomerError != null) throw fallbackCustomerError!;
    return (customerId: null, customerName: null, note: null);
  }
}

/// Error de negocio del bundle (no de red), como lo envuelve el repositorio:
/// p. ej. la BD viva sin una columna que el RPC espera.
Exception _bundleBroken() => Exception(
  'Error al obtener bundle de orden: PostgrestException(message: column '
  '"x" does not exist, code: 42703)',
);

Order _order(String id, {String status = 'open'}) => Order.fromMap({
  'id': id,
  'session_id': 'session-$id',
  'status_ext': status,
  'subtotal': 100,
  'total': 100,
  'created_at': '2026-10-09T12:00:00Z',
  if (status == 'paid' || status == 'void')
    'closed_at': '2026-10-09T13:00:00Z',
});

OrderItem _item(String id, String orderId, {double price = 100}) =>
    OrderItem.fromMap({
      'id': id,
      'order_id': orderId,
      'product_name': 'Producto $id',
      'product_id': 'product-$id',
      'qty': 1,
      'unit_price': price,
      'subtotal': price,
      'total': price,
      'status': 'draft',
      'created_at': '2026-10-09T12:00:00Z',
    });

/// Ítem como lo trae el servidor: con su extra y su línea de impuesto.
OrderItem _fullItem(String id, String orderId) => _item(id, orderId).copyWith(
  modifiers: [
    OrderItemModifier.fromMap({
      'id': 'mod-$id',
      'item_id': id,
      'name': 'Queso extra',
      'qty': 1,
      'price': 25,
    }),
  ],
  taxLines: [
    OrderItemTaxLine.fromMap({
      'id': 'tax-$id',
      'order_item_id': id,
      'tax_id': 'itbis',
      'tax_name': 'ITBIS',
      'tax_rate': 18,
      'amount': 18,
      'created_at': '2026-10-09T12:00:00Z',
    }),
  ],
);

CurrentOrderState _sale(String id) => CurrentOrderState(
  origin: 'table',
  order: _order(id),
  items: [_item('tmp_$id', id)],
);

_Bundle _bundle(Order order, List<OrderItem> items) => (
  order: order,
  items: items,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final offline = OfflinePosService();
  final keys = <String, String>{};
  final queueReads = _QueueReads();
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
    db = OfflineQueueDb.inMemory(
      NativeDatabase.memory().interceptWith(queueReads),
    );
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
    _Repository repository,
    CurrentOrderState initial,
  ) {
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
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> enqueueAddItem(
    String biz,
    String orderId, {
    String status = 'pending',
  }) => offline.enqueueAction(
    businessId: biz,
    action: {
      'type': 'add_item',
      'order_id': orderId,
      'item_id': 'tmp_$orderId',
      'menu_item_id': 'product',
      'qty': 1,
      'status': status,
      if (status != 'pending') 'attempts': 8,
      if (status == 'failed')
        'next_retry_at': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
    },
  );

  group('respaldo de la recarga (bundle roto, no por red)', () {
    test(
      'se aplica COMPLETO: ítems con sus extras y líneas de impuesto',
      () async {
        const biz = 'reload-fallback-complete';
        final repository = _Repository(repoClient)
          ..bundleError = _bundleBroken()
          ..fallbackOrder = _order('order-a1')
          ..fallbackItems = [_fullItem('item-fresh', 'order-a1')];
        final c = container(biz, repository, _sale('order-a1'));

        await c.read(currentOrderProvider.notifier).reloadOrderNow();

        final state = c.read(currentOrderProvider);
        expect(repository.itemReads, [true]);
        expect(state.order?.id, 'order-a1');
        expect(state.items.map((i) => i.id), ['item-fresh']);
        expect(state.items.single.modifiers.map((m) => m.name), [
          'Queso extra',
        ]);
        expect(state.items.single.taxLines.map((t) => t.taxName), ['ITBIS']);
        expect(state.error ?? '', isNot(contains('No se pudo actualizar')));
        expect(state.loading, isFalse);
      },
    );

    for (final failing in ['ítems/impuestos', 'cliente']) {
      test(
        'respaldo incompleto ($failing) conserva la pantalla con aviso',
        () async {
          final biz = 'reload-fallback-partial-${failing.hashCode}';
          final initial = _sale('order-a2');
          final repository = _Repository(repoClient)
            ..bundleError = _bundleBroken()
            ..fallbackOrder = _order('order-a2')
            ..fallbackItems = [_fullItem('item-fresh', 'order-a2')];
          if (failing == 'cliente') {
            repository.fallbackCustomerError = Exception(
              'Error al obtener cliente de la sesión: permiso denegado',
            );
          } else {
            repository.fallbackItemsError = Exception(
              'Error al obtener items: tax lines rejected',
            );
          }
          final c = container(biz, repository, initial);

          await c.read(currentOrderProvider.notifier).reloadOrderNow();

          final state = c.read(currentOrderProvider);
          expect(state.order?.id, 'order-a2');
          expect(state.items, initial.items);
          expect(state.loading, isFalse);
          expect(state.error, contains('Se conserva la venta guardada'));
        },
      );
    }

    test(
      'un "no existe" del servidor limpia la cuenta en vez de un error fijo',
      () async {
        const biz = 'reload-fallback-not-found';
        final repository = _Repository(repoClient)
          ..bundleError = _bundleBroken()
          ..fallbackOrder = null
          ..fallbackItems = const [];
        final c = container(biz, repository, _sale('order-a3'));

        await c.read(currentOrderProvider.notifier).reloadOrderNow();

        final state = c.read(currentOrderProvider);
        expect(state.order, isNull);
        expect(state.items, isEmpty);
        expect(state.loading, isFalse);
        expect(state.error ?? '', isNot(contains('Se conserva la venta')));
        expect(state.error, contains('order=…order-a3'));
      },
    );
  });

  group('operaciones fallidas o muertas en la cola', () {
    test(
      'cuenta cobrada en otro equipo: se adopta el cierre (sin cuenta fantasma) '
      'y la cola no se toca',
      () async {
        const biz = 'dead-action-server-paid';
        final repository = _Repository(repoClient)
          ..bundle = _bundle(_order('order-b1', status: 'paid'), const []);
        final c = container(biz, repository, _sale('order-b1'));
        await enqueueAddItem(biz, 'order-b1', status: 'dead');

        // El eco de Realtime del UPDATE en orders (refreshOrder(clearIfPaid)).
        await c
            .read(currentOrderProvider.notifier)
            .refreshOrder(clearIfPaid: true);
        await _waitUntil(() => c.read(currentOrderProvider).order == null);

        expect(repository.loaded, ['order-b1']);
        expect(c.read(currentOrderProvider).items, isEmpty);
        expect(
          await offline.hasUnsettledOrderActions(
            businessId: biz,
            orderId: 'order-b1',
          ),
          isTrue,
        );
      },
    );

    test(
      'antes de la precuenta: la cuenta anulada en el servidor reemplaza la local '
      'cuando sus altas ya no pueden subir (muertas)',
      () async {
        const biz = 'failed-action-server-void';
        final repository = _Repository(repoClient)
          ..bundle = _bundle(_order('order-b2', status: 'void'), const []);
        final c = container(biz, repository, _sale('order-b2'));
        await enqueueAddItem(biz, 'order-b2', status: 'dead');

        await c.read(currentOrderProvider.notifier).reloadOrderNow();

        final state = c.read(currentOrderProvider);
        expect(repository.loaded, ['order-b2']);
        expect(state.order?.status, 'void');
        expect(state.items, isEmpty);
        expect(state.loading, isFalse);
        expect(
          await offline.hasUnsettledOrderActions(
            businessId: biz,
            orderId: 'order-b2',
          ),
          isTrue,
        );
      },
    );

    for (final status in ['failed', 'dead']) {
      test(
        'acción $status y cuenta abierta en el servidor: se lee el servidor y '
        'se conserva lo local',
        () async {
          final biz = 'unsettled-$status-server-open';
          final initial = _sale('order-b3');
          final repository = _Repository(repoClient)
            ..bundle = _bundle(_order('order-b3'), [
              _fullItem('item-server-only', 'order-b3'),
            ]);
          final c = container(biz, repository, initial);
          await enqueueAddItem(biz, 'order-b3', status: status);

          await c.read(currentOrderProvider.notifier).reloadOrderNow();

          final state = c.read(currentOrderProvider);
          expect(repository.loaded, ['order-b3']);
          expect(state.order?.id, 'order-b3');
          expect(state.items, initial.items);
          expect(state.loading, isFalse);
        },
      );
    }

    test('borrador local con cola pendiente no consulta el servidor', () async {
      const biz = 'unsettled-local-draft';
      final initial = _sale('local-order-b4');
      final repository = _Repository(repoClient);
      final c = container(biz, repository, initial);
      await enqueueAddItem(biz, 'local-order-b4');

      await c.read(currentOrderProvider.notifier).refreshOrder();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(repository.loaded, isEmpty);
      expect(c.read(currentOrderProvider).items, initial.items);
    });
  });

  group('anulada sin cobro con altas aún por subir (no es definitiva)', () {
    // El barrendero de mesas vacías (fn_release_empty_tables) anula la cuenta
    // que quedó vacía en el servidor mientras sus altas siguen en la cola; al
    // subirlas, el trigger de order_items (20260819_0004) la resucita.
    for (final status in ['pending', 'processing', 'failed']) {
      test(
        'alta $status: la precuenta conserva los productos locales y el '
        'respaldo no se pisa con la anulada',
        () async {
          final biz = 'reviving-add-$status-server-void';
          final initial = _sale('order-d1');
          final repository = _Repository(repoClient)
            ..bundle = _bundle(_order('order-d1', status: 'void'), const []);
          final c = container(biz, repository, initial);
          await enqueueAddItem(biz, 'order-d1', status: status);

          await c.read(currentOrderProvider.notifier).reloadOrderNow();

          final state = c.read(currentOrderProvider);
          expect(repository.loaded, ['order-d1']);
          expect(state.order?.id, 'order-d1');
          expect(state.order?.status, 'open');
          expect(state.items, initial.items);
          expect(state.loading, isFalse);
          // Mesa sin tableId: el respaldo usa la sesión de la orden como slot.
          final saved = await offline.loadSnapshot(
            businessId: biz,
            slotId: 'session-order-d1',
          );
          expect(saved?.order?.status, isNot('void'));
          expect(
            await offline.hasUnsettledOrderActions(
              businessId: biz,
              orderId: 'order-d1',
            ),
            isTrue,
          );
        },
      );
    }

    test(
      'cobrada en el servidor: se adopta aunque haya altas pendientes',
      () async {
        const biz = 'reviving-add-server-paid';
        final repository = _Repository(repoClient)
          ..bundle = _bundle(_order('order-d2', status: 'paid'), const []);
        final c = container(biz, repository, _sale('order-d2'));
        await enqueueAddItem(biz, 'order-d2');

        await c
            .read(currentOrderProvider.notifier)
            .refreshOrder(clearIfPaid: true);
        await _waitUntil(() => c.read(currentOrderProvider).order == null);

        expect(repository.loaded, ['order-d2']);
        expect(
          await offline.hasUnsettledOrderActions(
            businessId: biz,
            orderId: 'order-d2',
          ),
          isTrue,
        );
      },
    );

    test(
      'anulada con solo cambios que no agregan productos: se adopta el cierre',
      () async {
        const biz = 'non-add-pending-server-void';
        final repository = _Repository(repoClient)
          ..bundle = _bundle(_order('order-d3', status: 'void'), const []);
        final c = container(biz, repository, _sale('order-d3'));
        await offline.enqueueAction(
          businessId: biz,
          action: {
            'type': 'update_item_notes',
            'order_id': 'order-d3',
            'item_id': 'tmp_order-d3',
            'notes': 'sin cebolla',
          },
        );

        await c.read(currentOrderProvider.notifier).reloadOrderNow();

        final state = c.read(currentOrderProvider);
        expect(state.order?.status, 'void');
        expect(state.items, isEmpty);
      },
    );

    for (final status in ['pending', 'dead', 'paid']) {
      final resumes = status == 'pending';
      test(
        'venta rápida barrida (sesión cerrada) con alta '
        '${status == 'paid' ? 'pendiente y cobrada' : status}: '
        '${resumes ? 'se retoma, sin abrir otra' : 'se abre una venta nueva'}',
        () async {
          final biz = 'swept-quick-resume-$status';
          await offline.saveSnapshot(
            businessId: biz,
            slotId: 'quick',
            origin: 'quick',
            state: _sale('order-q1').copyWith(origin: 'quick'),
          );
          final repository = _Repository(repoClient)
            ..session = (origin: 'quick', closedAt: DateTime(2026, 10, 9, 12))
            ..bundles['order-q1'] = _bundle(
              _order('order-q1', status: status == 'paid' ? 'paid' : 'void'),
              const [],
            )
            ..bundles['order-new'] = _bundle(_order('order-new'), const []);
          final c = container(biz, repository, const CurrentOrderState());
          await enqueueAddItem(
            biz,
            'order-q1',
            status: status == 'dead' ? 'dead' : 'pending',
          );

          await c.read(currentOrderProvider.notifier).ensureQuickOrder();

          final state = c.read(currentOrderProvider);
          expect(state.origin, 'quick');
          expect(state.loading, isFalse);
          final saved = await offline.loadSnapshot(
            businessId: biz,
            slotId: 'quick',
          );
          if (resumes) {
            expect(repository.opens, 0);
            expect(state.order?.id, 'order-q1');
            expect(state.items.map((i) => i.id), ['tmp_order-q1']);
            expect(saved?.order?.id, 'order-q1');
            expect(saved?.order?.status, 'open');
          } else {
            expect(repository.opens, 1);
            expect(state.order?.id, 'order-new');
            expect(saved?.order?.id, 'order-new');
          }
        },
      );
    }
  });

  group('cierre adoptado y luego reabierto en el servidor', () {
    for (final reopen in ['alta resucitada', 'cobro anulado']) {
      test('$reopen: se aplica la cuenta reabierta aunque quede una '
          'operación muerta', () async {
        final biz = 'adopted-closure-reopened-${reopen.hashCode}';
        // Lo que dejó en pantalla la adopción del cierre: cerrada y vacía.
        final adopted = CurrentOrderState(
          origin: 'table',
          order: _order(
            'order-e1',
            status: reopen == 'alta resucitada' ? 'void' : 'paid',
          ),
          items: const <OrderItem>[],
        );
        final repository = _Repository(repoClient)
          ..bundle = _bundle(
            _order(
              'order-e1',
              status: reopen == 'alta resucitada' ? 'open' : 'partially_paid',
            ),
            [_fullItem('item-server', 'order-e1')],
          );
        final c = container(biz, repository, adopted);
        await enqueueAddItem(biz, 'order-e1', status: 'dead');

        await c.read(currentOrderProvider.notifier).reloadOrderNow();

        final state = c.read(currentOrderProvider);
        expect(repository.loaded, ['order-e1']);
        expect(state.order?.closedAt, isNull);
        expect(state.order?.status, isNot(anyOf('void', 'paid')));
        expect(state.items.map((i) => i.id), ['item-server']);
        expect(state.loading, isFalse);
      });
    }
  });

  group('lecturas de la cola por recarga', () {
    for (final backlog in [false, true]) {
      test(
        backlog
            ? 'con muertas de OTRA cuenta: una sola lectura completa'
            : 'sin nada sin completar: ninguna lectura completa',
        () async {
          final biz = 'queue-reads-backlog-$backlog';
          if (backlog) {
            await enqueueAddItem(biz, 'order-other', status: 'dead');
          }
          final repository = _Repository(repoClient)
            ..bundle = _bundle(_order('order-f1'), [
              _fullItem('item-server', 'order-f1'),
            ]);
          final c = container(biz, repository, _sale('order-f1'));
          queueReads.counts.remove(biz);

          await c.read(currentOrderProvider.notifier).reloadOrderNow();

          expect(
            c.read(currentOrderProvider).items.map((i) => i.id),
            ['item-server'],
          );
          expect(queueReads.counts[biz] ?? 0, backlog ? 1 : 0);
        },
      );
    }
  });

  group('alta que cae a la cola durante la lectura', () {
    for (final queuedDuringRead in [true, false]) {
      test(
        queuedDuringRead
            ? 'con un alta en cola, la respuesta vieja no borra el producto'
            : 'sin cola, la respuesta del servidor sí se aplica',
        () async {
          final biz = 'queued-during-read-$queuedDuringRead';
          final initial = _sale('order-c1');
          final repository = _Repository(repoClient)
            ..deferredBundle = Completer<_Bundle>();
          final c = container(biz, repository, initial);

          final reload = c.read(currentOrderProvider.notifier).reloadOrderNow();
          await _waitUntil(() => repository.loaded.contains('order-c1'));
          if (queuedDuringRead) await enqueueAddItem(biz, 'order-c1');
          repository.deferredBundle!.complete(
            _bundle(_order('order-c1'), [
              _fullItem('item-server', 'order-c1'),
            ]),
          );
          await reload;

          final state = c.read(currentOrderProvider);
          expect(state.order?.id, 'order-c1');
          expect(state.loading, isFalse);
          if (queuedDuringRead) {
            expect(state.items, initial.items);
          } else {
            expect(state.items.map((i) => i.id), ['item-server']);
          }
        },
      );
    }
  });
}
