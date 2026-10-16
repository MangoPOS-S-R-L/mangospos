import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mangopos/data/models/order_edit.dart';
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
  SessionState build() => SessionState(
    activeBusinessId: businessId,
    permissions: {'ventas.orden.agregar_item', 'ventas.orden.editar_item'},
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

typedef _AddResult = ({String itemId, bool replayed, bool itemExists});

class _Repository extends SalesRepository {
  _Repository(super.client);
  final started = <String, Completer<void>>{};
  final additions = <String, Completer<_AddResult>>{};
  final deletions = <String, Completer<void>>{};
  final quantities = <double, Completer<void>>{};
  final offers = <String, Completer<void>>{};
  final loaded = <String>[];
  Future<void> waitFor(String operation) =>
      started.putIfAbsent(operation, Completer<void>.new).future;
  void start(String operation) =>
      started.putIfAbsent(operation, Completer<void>.new).complete();

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
    final result = additions.putIfAbsent(menuItemId, Completer<_AddResult>.new);
    start('add-$menuItemId');
    return result.future;
  }

  @override
  Future<String?> addOfferDealItem({
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    required double discount,
    required String name,
    String? promotionId,
    int checkPosition = 1,
    String? clientOpId,
    String? createdByEmployeeId,
  }) async {
    final result = offers.putIfAbsent(menuItemId, Completer<void>.new);
    start('offer-$menuItemId');
    await result.future;
    return null;
  }

  @override
  Future<OrderEditResult> deleteItem({
    required String itemId,
    required OrderEdit edit,
  }) async {
    final result = deletions.putIfAbsent(itemId, Completer<void>.new);
    start('delete-$itemId');
    await result.future;
    return const OrderEditResult(status: 'applied');
  }

  @override
  Future<OrderEditResult> updateItemQuantity({
    required String itemId,
    required double quantity,
    required OrderEdit edit,
  }) async {
    final result = quantities.putIfAbsent(quantity, Completer<void>.new);
    start('qty-$quantity');
    await result.future;
    return const OrderEditResult(status: 'applied');
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

CurrentOrderState _sale(String id, {String origin = 'quick'}) =>
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final offline = OfflinePosService();
  final secureStore = <String, String>{};
  late OfflineQueueDb db;
  late SupabaseClient client;
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            if (call.method == 'write')
              secureStore[args['key'] as String] = args['value'] as String;
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
  });
  tearDownAll(() async {
    await db.close();
    await client.dispose();
  });

  Future<ProviderContainer> prepare(
    String biz,
    _Repository repository, {
    CurrentOrderState? initial,
  }) async {
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await offline.saveSnapshot(
      businessId: biz,
      slotId: 'quick',
      origin: 'quick',
      state: initial ?? _sale('A'),
    );
    await offline.saveSnapshot(
      businessId: biz,
      slotId: 'table-B',
      tableId: 'table-B',
      origin: 'table',
      state: _sale('B', origin: 'table'),
    );
    ConnectivityService().simulateReconnect();
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(() => _Sales(initial ?? _sale('A'))),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        byZoneVmProvider.overrideWith(_Zones.new),
        fiscalServiceProvider.overrideWithValue(_Fiscal()),
        salesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> goToB(SalesViewModel vm) async {
    ConnectivityService().simulateDisconnect();
    await vm.openTable('table-B');
    ConnectivityService().simulateReconnect();
  }

  for (final kind in ['add', 'delete', 'qty']) {
    for (final outcome in ['rejected', 'saved', 'network']) {
      test(
        '$kind $outcome después de navegar conserva B y el respaldo de A',
        () async {
          final biz = 'mutation-$kind-$outcome';
          final repository = _Repository(client);
          final container = await prepare(biz, repository);
          final vm = container.read(currentOrderProvider.notifier);
          final Future<dynamic> action;
          if (kind == 'add') {
            action = vm.addItem(
              menuItemId: 'new',
              productName: 'Nuevo',
              productPrice: 25,
              productTaxRate: 0,
            );
            await repository.waitFor('add-new');
          } else if (kind == 'delete') {
            action = vm.deleteItem('item-A');
            await repository.waitFor('delete-item-A');
          } else {
            action = vm.updateItemQuantity('item-A', 2);
            await repository.waitFor('qty-2.0');
          }
          await goToB(vm);
          final before = container.read(currentOrderProvider);
          if (outcome == 'saved') {
            if (kind == 'add')
              repository.additions['new']!.complete((
                itemId: 'real-new',
                replayed: false,
                itemExists: false,
              ));
            if (kind == 'delete') repository.deletions['item-A']!.complete();
            if (kind == 'qty') repository.quantities[2]!.complete();
          } else {
            final error = outcome == 'network'
                ? TimeoutException('lost response')
                : StateError('rejected');
            if (kind == 'add')
              repository.additions['new']!.completeError(error);
            if (kind == 'delete')
              repository.deletions['item-A']!.completeError(error);
            if (kind == 'qty') repository.quantities[2]!.completeError(error);
          }
          await action;
          expect(container.read(currentOrderProvider).order, before.order);
          expect(container.read(currentOrderProvider).items, before.items);
          expect(repository.loaded, isEmpty);
          final saved = await offline.loadSnapshot(
            businessId: biz,
            slotId: 'quick',
          );
          expect(saved?.order?.id, 'order-A');
          if (kind == 'add')
            expect(saved!.items.length, outcome == 'rejected' ? 1 : 2);
          if (kind == 'delete')
            expect(saved!.items.length, outcome == 'rejected' ? 1 : 0);
          if (kind == 'qty')
            expect(saved!.items.single.quantity, outcome == 'rejected' ? 1 : 2);
          if (outcome == 'network') {
            final queued = (await offline.unsettledActions(biz)).single;
            expect(queued['order_id'], 'order-A');
            expect(queued['origin'], 'quick');
            expect(queued['slot_id'], 'quick');
          }
        },
      );
    }
  }

  test(
    'grupo offline: una intención durable recupera la cuenta aunque el snapshot sea antiguo',
    () async {
      const biz = 'durable-group-offline';
      final repo = _Repository(client);
      final initial = _sale('A');
      final base = initial.items.single.copyWith(
        quantity: 4,
        unitPrice: 250,
        subtotal: 1000,
        tax: 0,
        discounts: 250,
        total: 750,
        status: 'pending',
        notes: '[DEAL:promo]\n[DEAL_RULE:4:250.00]',
      );
      final rows = [base, base.copyWith(id: 'item-A2')];
      final before = initial.copyWith(
        items: rows,
        order: initial.order!.copyWith(
          subtotal: 2000,
          discounts: 500,
          total: 1500,
        ),
      );
      final container = await prepare(biz, repo, initial: before);
      ConnectivityService().simulateDisconnect();
      final ok = await container
          .read(currentOrderProvider.notifier)
          .saveItemGroup(rows, base.copyWith(quantity: 6));
      expect(ok, true);
      final queue = await offline.unsettledActions(biz);
      expect(queue, hasLength(1));
      expect(queue.single['type'], 'edit_item_group');
      expect(queue.single['actions'], hasLength(2));
      expect(container.read(currentOrderProvider).order!.total, 1250);
      expect(repo.quantities, isEmpty);
      await offline.saveSnapshot(
        businessId: biz,
        slotId: 'quick',
        origin: 'quick',
        state: before,
      );
      final recovered = (await offline.loadSnapshot(
        businessId: biz,
        slotId: 'quick',
      ))!;
      expect(recovered.items.fold<double>(0, (s, i) => s + i.quantity), 6);
      expect(recovered.order!.total, 1250);
      expect(recovered.items.map((i) => i.discounts), [250, 0]);
    },
  );

  for (final (after, singleEntry) in [(3.0,false),(0.0,false),(3.0,true)]) {
    test('retirar oferta legacy a $after se guarda offline sin bloquear', () async {
      final biz = 'legacy-group-$after-$singleEntry';
      final repo = _Repository(client);
      final initial = _sale('A');
      final row = initial.items.single.copyWith(
        productName: '4x3 Presidente', quantity: 4, unitPrice: 250,
        subtotal: 1000, tax: 0, discounts: 250, total: 750,
        notes: '[DEAL:promo]', status: 'pending');
      final before = initial.copyWith(items: [row], order: initial.order!
        .copyWith(subtotal: 1000, discounts: 250, total: 750));
      final container = await prepare(biz, repo, initial: before);
      ConnectivityService().simulateDisconnect();
      final vm = container.read(currentOrderProvider.notifier);
      if (singleEntry) {
        await vm.updateItemQuantity(row.id, after);
      } else {
        expect(await vm.saveItemGroup([row], row.copyWith(quantity: after)),true);
      }
      final queue = await offline.unsettledActions(biz);
      expect(queue, hasLength(1));
      final saved = container.read(currentOrderProvider);
      expect(saved.order!.total, after == 0 ? 0 : 750);
      expect(saved.items.fold<double>(0, (s,i) => s+i.quantity), after);
      if (after != 0) {
        expect(saved.items.single.notes, contains('[DEAL_RULE:4:250.00]'));
        expect(saved.items.single.discounts, 0);
      }
    });
  }

  test('grupo guardándose al navegar no modifica la otra mesa', () async {
    const biz = 'group-navigation';
    final repo = _Repository(client);
    final original = _sale('A');
    final container = await prepare(biz, repo);
    final vm = container.read(currentOrderProvider.notifier);
    ConnectivityService().simulateDisconnect();
    final change = vm.saveItemGroup(
      original.items,
      original.items.single.copyWith(quantity: 2),
    );
    await goToB(vm);
    final other = container.read(currentOrderProvider);
    expect(await change, true);
    expect(container.read(currentOrderProvider).order, other.order);
    expect(container.read(currentOrderProvider).items, other.items);
    final saved = (await offline.loadSnapshot(
      businessId: biz,
      slotId: 'quick',
    ))!;
    expect(saved.order!.id, 'order-A');
    expect(saved.items.single.quantity, 2);
    expect((await offline.unsettledActions(biz)).single['order_id'], 'order-A');
  });

  for (final qty in [4.0, 6.0, 7.0]) {
    for (final outcome in ['saved', 'rejected', 'network']) {
      test(
        'oferta de 8 a $qty: $outcome conserva descuento, respaldo y rollback',
        () async {
          final biz = 'offer-quantity-$qty-$outcome';
          final repository = _Repository(client);
          final initial = _sale('A');
          final row = initial.items.single.copyWith(
            quantity: 8,
            unitPrice: 250,
            subtotal: 2000,
            tax: 0,
            discounts: 500,
            total: 1500,
            notes: '[DEAL:promo]\n[DEAL_RULE:4:250.00]',
          );
          final container = await prepare(
            biz,
            repository,
            initial: initial.copyWith(
              items: [row],
              order: initial.order!.copyWith(
                subtotal: 2000,
                discounts: 500,
                total: 1500,
              ),
            ),
          );
          final vm = container.read(currentOrderProvider.notifier);
          final action = vm.updateItemQuantity(row.id, qty);
          await repository.waitFor('qty-$qty');
          final optimistic = container.read(currentOrderProvider);
          expect(optimistic.items.single.discounts, 250);
          expect(optimistic.order!.discounts, 250);
          expect(optimistic.order!.total, qty * 250 - 250);
          if (outcome == 'saved') {
            repository.quantities[qty]!.complete();
          } else {
            repository.quantities[qty]!.completeError(
              outcome == 'network'
                  ? TimeoutException('respuesta perdida')
                  : StateError('edición rechazada'),
            );
          }
          await action;
          final expectedQty = outcome == 'rejected' ? 8.0 : qty;
          final expectedDiscount = outcome == 'rejected' ? 500.0 : 250.0;
          expect(
            container.read(currentOrderProvider).items.single.quantity,
            expectedQty,
          );
          expect(
            container.read(currentOrderProvider).items.single.discounts,
            expectedDiscount,
          );
          final saved = (await offline.loadSnapshot(
            businessId: biz,
            slotId: 'quick',
          ))!;
          expect(saved.items.single.quantity, expectedQty);
          expect(saved.items.single.discounts, expectedDiscount);
          if (outcome == 'network') {
            final queue = (await offline.unsettledActions(
              biz,
            )).where((a) => a['type'] == 'update_item_quantity');
            expect(queue, hasLength(1));
            expect((queue.single['item_snapshot'] as Map)['discounts'], 250);
          }
        },
      );
    }
  }

  test(
    'oferta antigua sin regla no inventa un descuento sin conexión',
    () async {
      const biz = 'legacy-offer-no-rule-offline';
      final repository = _Repository(client);
      final initial = _sale('A');
      final row = initial.items.single.copyWith(
        quantity: 8,
        unitPrice: 250,
        subtotal: 2000,
        tax: 0,
        discounts: 500,
        total: 1500,
        notes: '[DEAL:promo]',
      );
      final container = await prepare(
        biz,
        repository,
        initial: initial.copyWith(
          items: [row],
          order: initial.order!.copyWith(
            subtotal: 2000,
            discounts: 500,
            total: 1500,
          ),
        ),
      );
      ConnectivityService().simulateDisconnect();
      await container
          .read(currentOrderProvider.notifier)
          .updateItemQuantity(row.id, 4);
      final current = container.read(currentOrderProvider);
      expect(current.items.single.quantity, 8);
      expect(current.items.single.discounts, 500);
      expect(current.error, contains('Necesita conexión'));
      expect(repository.quantities, isEmpty);
      expect(await offline.unsettledActions(biz), isEmpty);
    },
  );

  test('alta fallida no borra otra alta concurrente confirmada', () async {
    const biz = 'concurrent-add-rollback';
    final repository = _Repository(client);
    final container = await prepare(biz, repository);
    final vm = container.read(currentOrderProvider.notifier);
    final first = vm.addItem(
      menuItemId: 'one',
      productName: 'Uno',
      productPrice: 20,
    );
    await repository.waitFor('add-one');
    final second = vm.addItem(
      menuItemId: 'two',
      productName: 'Dos',
      productPrice: 30,
    );
    await repository.waitFor('add-two');
    repository.additions['two']!.complete((
      itemId: 'real-two',
      replayed: false,
      itemExists: false,
    ));
    await second;
    ConnectivityService().simulateReconnect();
    repository.additions['one']!.completeError(StateError('one rejected'));
    await first;
    final items = container.read(currentOrderProvider).items;
    expect(items.map((item) => item.productName), ['Producto A', 'Dos']);
    expect(items.last.id, 'real-two');
    expect(
      (await offline.loadSnapshot(businessId: biz, slotId: 'quick'))!.items,
      items,
    );
  });

  test('oferta rechazada quita solo su línea y conserva el producto agregado '
      'mientras esperaba', () async {
    const biz = 'offer-rollback-keeps-add';
    final repository = _Repository(client);
    final container = await prepare(biz, repository);
    final vm = container.read(currentOrderProvider.notifier);
    final offer = vm.addOfferDeal(
      menuItemId: 'combo',
      lineQty: 1,
      discount: 5,
      name: 'Combo',
      originalPrice: 25,
    );
    await repository.waitFor('offer-combo');
    // El alta en vuelo debe usar la misma base pre-descuento que el servidor.
    final optimistic = container.read(currentOrderProvider).items.last;
    expect(optimistic.subtotal, 25);
    expect(optimistic.discounts, 5);
    expect(
      optimistic.total,
      closeTo(optimistic.subtotal + optimistic.tax - 5, 0.01),
    );
    final add = vm.addItem(
      menuItemId: 'two',
      productName: 'Dos',
      productPrice: 30,
    );
    await repository.waitFor('add-two');
    repository.additions['two']!.complete((
      itemId: 'real-two',
      replayed: false,
      itemExists: false,
    ));
    await add;
    repository.offers['combo']!.completeError(StateError('oferta rechazada'));
    await offer;

    final shown = container.read(currentOrderProvider);
    expect(shown.items.map((item) => item.productName), ['Producto A', 'Dos']);
    expect(shown.items.last.id, 'real-two');
    expect(shown.error, contains('No se pudo agregar la oferta'));
    final expectedTotal = shown.items.fold<double>(
      0,
      (sum, item) => sum + item.total,
    );
    expect(shown.order!.total, closeTo(expectedTotal, 0.01));
  });

  test(
    'borrado fallido restaura su línea conservando el producto nuevo',
    () async {
      const biz = 'delete-rollback-new-add';
      final repository = _Repository(client);
      final container = await prepare(biz, repository);
      final vm = container.read(currentOrderProvider.notifier);
      final deletion = vm.deleteItem('item-A');
      await repository.waitFor('delete-item-A');
      final addition = vm.addItem(
        menuItemId: 'new',
        productName: 'Nuevo',
        productPrice: 20,
      );
      await repository.waitFor('add-new');
      repository.additions['new']!.complete((
        itemId: 'real-new',
        replayed: false,
        itemExists: false,
      ));
      await addition;
      ConnectivityService().simulateReconnect();
      repository.deletions['item-A']!.completeError(
        StateError('delete rejected'),
      );
      await deletion;
      expect(
        container
            .read(currentOrderProvider)
            .items
            .map((item) => item.productName),
        ['Producto A', 'Nuevo'],
      );
    },
  );

  test(
    'cantidad fallida no revierte una edición posterior confirmada',
    () async {
      const biz = 'quantity-rollback-new-edit';
      final repository = _Repository(client);
      final container = await prepare(biz, repository);
      final vm = container.read(currentOrderProvider.notifier);
      final first = vm.updateItemQuantity('item-A', 2);
      await repository.waitFor('qty-2.0');
      // T04: la segunda edición de la misma línea espera en fila a la
      // primera (manda la versión que esta deje).
      final second = vm.updateItemQuantity('item-A', 3);
      repository.quantities[2]!.completeError(StateError('old qty rejected'));
      await first;
      expect(container.read(currentOrderProvider).items.single.quantity, 3);
      await repository.waitFor('qty-3.0');
      repository.quantities[3]!.complete();
      await second;
      expect(container.read(currentOrderProvider).items.single.quantity, 3);
      expect(
        (await offline.loadSnapshot(
          businessId: biz,
          slotId: 'quick',
        ))!.items.single.quantity,
        3,
      );
    },
  );

  test(
    'cantidad vieja que falla por red con otra más nueva en fila no se encola',
    () async {
      const biz = 'quantity-stale-not-queued';
      final repository = _Repository(client);
      final container = await prepare(biz, repository);
      final vm = container.read(currentOrderProvider.notifier);
      final first = vm.updateItemQuantity('item-A', 2);
      await repository.waitFor('qty-2.0');
      final second = vm.updateItemQuantity('item-A', 3);
      // El 2 se queda sin respuesta: encolarlo dejaría 2 al sincronizar,
      // encima del 3 que va detrás.
      repository.quantities[2]!.completeError(
        Exception('ClientException: Connection reset by peer'),
      );
      await first;
      await repository.waitFor('qty-3.0');
      repository.quantities[3]!.complete();
      await second;

      expect(container.read(currentOrderProvider).items.single.quantity, 3);
      final queued = (await offline.unsettledActions(
        biz,
      )).where((a) => a['type'] == 'update_item_quantity').toList();
      expect(queued, isEmpty);
      expect(
        (await offline.loadSnapshot(
          businessId: biz,
          slotId: 'quick',
        ))!.items.single.quantity,
        3,
      );
    },
  );
}
