import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mangopos/core/business/business_model.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/hub/hub_state_db.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/models/fiscal_models.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/presentation/inventory/viewmodel/inventory_viewmodel.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/state/by_zone_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/retail_carts_provider.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/services/fiscal/fiscal_service.dart';
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
  final slots = <String>[];
  final loaded = <String>[];
  final added = <String>[];
  bool failModifiers = false;
  int sharedOpens = 0;
  Completer<Map<String, dynamic>>? deferredSharedOpen;
  final offlineOrigins = <String>[];
  final tables = <String>[];

  @override
  Future<Map<String, dynamic>> openOfflineSale({
    required String origin,
    required String slot,
    required String businessId,
  }) async {
    offlineOrigins.add(origin);
    slots.add(slot);
    return {'order_id': 'remote-$slot'};
  }

  @override
  Future<Map<String, dynamic>> openTable({
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    tables.add(tableId);
    return {'order_id': 'remote-table-$tableId'};
  }

  @override
  Future<Map<String, dynamic>> openRetailCart({
    required String slot,
    required String businessId,
    int peopleCount = 1,
  }) async {
    slots.add(slot);
    return {'order_id': 'remote-$slot'};
  }

  @override
  Future<Map<String, dynamic>> openManualOrQuick({
    required String origin,
    String? customerName,
    int peopleCount = 1,
    String? businessId,
  }) async {
    sharedOpens++;
    if (deferredSharedOpen != null) return deferredSharedOpen!.future;
    return {'order_id': 'shared-order'};
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
  Future<void> replaceOrderItemModifiers({
    required String itemId,
    required List<Map<String, dynamic>> modifiers,
  }) async {
    if (failModifiers) throw StateError('modifier rejected');
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
    throw TimeoutException('bundle response lost');
  }
}

CurrentOrderState sale(String id, {double total = 100}) => CurrentOrderState(
  origin: 'quick',
  order: Order.fromMap({
    'id': id,
    'session_id': 'session-$id',
    'status_ext': 'draft',
    'subtotal': total,
    'total': total,
    'created_at': '2026-10-09T12:00:00Z',
  }),
  items: [
    OrderItem.fromMap({
      'id': 'tmp_$id',
      'order_id': id,
      'product_name': 'Producto',
      'qty': 1,
      'unit_price': total,
      'subtotal': total,
      'total': total,
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
  late HubStateDb hubDb;
  late SupabaseClient client;
  late _Repository repository;
  setUpAll(() {
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
  });
  setUp(() {
    repository = _Repository(client);
    offline.setHubUploader(null);
    ConnectivityService().simulateReconnect();
  });
  tearDownAll(() async {
    await db.close();
    await hubDb.close();
    await client.dispose();
  });

  Future<void> enqueue(String biz, String orderId, {bool modifiers = false}) =>
      offline.enqueueAction(
        businessId: biz,
        action: {
          'type': 'add_item',
          'origin': 'quick',
          'order_id': orderId,
          'item_id': 'tmp_$orderId',
          'menu_item_id': 'product',
          'qty': 1,
          if (modifiers)
            'selected_modifiers': [
              {'name': 'Extra', 'qty': 1, 'price': 25},
            ],
        },
      );

  Future<OfflineQueueSyncResult> sync(String biz) => offline.syncPendingActions(
    businessId: biz,
    salesRepository: repository,
    printingService: PrintingService(client),
    inventoryRepository: InventoryRepository(client),
    cashierRepository: CashierRepository(client),
    force: true,
  );

  ProviderContainer container(
    String biz,
    CurrentOrderState initial, {
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

  test(
    'ventas rápidas sin snapshot suben separadas sin abrir mesa compartida',
    () async {
      const biz = 'paid-quick-no-snapshot';
      await enqueue(biz, 'local-order-one');
      await enqueue(biz, 'local-order-two');
      final result = await sync(biz);
      expect(result.completed, 2);
      expect(repository.slots, ['quick-one', 'quick-two']);
      expect(repository.sharedOpens, 0);
      expect(repository.added.toSet(), hasLength(2));
    },
  );

  test('ventas manuales offline conservan órdenes independientes', () async {
    const biz = 'manual-independent-offline';
    for (final id in ['local-order-manual-one', 'local-order-manual-two']) {
      await offline.enqueueAction(
        businessId: biz,
        action: {
          'type': 'add_item',
          'origin': 'manual',
          'order_id': id,
          'item_id': 'tmp_$id',
          'menu_item_id': 'product',
        },
      );
    }
    final result = await sync(biz);
    expect(result.completed, 2);
    expect(repository.offlineOrigins, ['manual', 'manual']);
    expect(repository.added.toSet(), hasLength(2));
    expect(repository.sharedOpens, 0);
  });

  for (final origin in ['table', 'delivery']) {
    test(
      '$origin conserva destino al retirar snapshot después de cobrar offline',
      () async {
        final biz = 'paid-$origin-context';
        final initial = sale(
          'local-order-paid-$origin',
        ).copyWith(origin: origin);
        await offline.saveSnapshot(
          businessId: biz,
          slotId: 'table-$origin',
          tableId: 'table-$origin',
          origin: origin,
          state: initial,
        );
        await offline.enqueueAction(
          businessId: biz,
          action: {
            'type': 'add_item',
            'order_id': initial.order!.id,
            'item_id': 'tmp_$origin',
            'menu_item_id': 'product',
          },
        );
        await offline.markOrderClosedLocally(
          businessId: biz,
          orderId: initial.order!.id,
        );
        expect(
          await offline.loadSnapshot(businessId: biz, slotId: 'table-$origin'),
          isNull,
        );
        final queued = (await offline.unsettledActions(biz)).single;
        expect(queued['origin'], origin);
        expect(queued['table_id'], 'table-$origin');
        final result = await sync(biz);
        expect(result.completed, 1);
        expect(repository.tables, ['table-$origin']);
      },
    );
  }

  test('sincronizar otra venta no reemplaza ni recarga la activa', () async {
    const biz = 'sync-another-cart';
    final initial = sale('local-order-active');
    final c = container(biz, initial);
    await enqueue(biz, 'local-order-other');
    await c
        .read(currentOrderProvider.notifier)
        .syncPendingOfflineActions(force: true);
    expect(c.read(currentOrderProvider).order?.id, initial.order!.id);
    expect(c.read(currentOrderProvider).items, initial.items);
    expect(repository.loaded, isEmpty);
  });

  test(
    'sync parcial conserva productos locales y bloquea recarga incompleta',
    () async {
      const biz = 'partial-cart-sync';
      final initial = sale('local-order-partial');
      final c = container(biz, initial);
      repository.failModifiers = true;
      await enqueue(biz, initial.order!.id, modifiers: true);
      await c
          .read(currentOrderProvider.notifier)
          .syncPendingOfflineActions(force: true);
      expect(c.read(currentOrderProvider).items, initial.items);
      expect(c.read(currentOrderProvider).order?.id, initial.order!.id);
      expect(repository.loaded, isEmpty);
      expect(
        await offline.hasUnsettledOrderActions(
          businessId: biz,
          orderId: 'remote-quick-partial',
        ),
        isTrue,
      );
    },
  );

  test(
    'recarga al terminar sync usa mapping activo y conserva venta si cae red',
    () async {
      const biz = 'mapped-active-network-loss';
      final initial = sale('local-order-original');
      final c = container(biz, initial);
      await enqueue(biz, initial.order!.id);
      await enqueue(biz, 'local-order-last-in-queue');
      await c
          .read(currentOrderProvider.notifier)
          .syncPendingOfflineActions(force: true);
      expect(repository.loaded, ['remote-quick-original']);
      expect(c.read(currentOrderProvider).order?.id, initial.order!.id);
      expect(c.read(currentOrderProvider).items, initial.items);
    },
  );

  test(
    'retomar venta rápida offline conserva snapshot al cambiar de pantalla',
    () async {
      const biz = 'resume-restaurant-quick';
      final initial = sale('local-order-resume');
      await offline.saveSnapshot(
        businessId: biz,
        slotId: 'quick',
        origin: 'quick',
        state: initial,
        localOnly: true,
      );
      ConnectivityService().simulateDisconnect();
      final c = container(biz, const CurrentOrderState());
      await c.read(currentOrderProvider.notifier).ensureQuickOrder();
      expect(c.read(currentOrderProvider).order?.id, initial.order!.id);
      expect(c.read(currentOrderProvider).items, initial.items);
      expect(repository.sharedOpens, 0);
    },
  );

  for (final openingFails in [false, true]) {
    test(
      'respuesta rápida tardía ${openingFails ? 'fallida' : 'exitosa'} no sustituye la venta manual elegida',
      () async {
        final biz = 'late-quick-$openingFails';
        repository.deferredSharedOpen = Completer<Map<String, dynamic>>();
        final c = container(biz, const CurrentOrderState());
        final vm = c.read(currentOrderProvider.notifier);
        final openingQuick = vm.openQuick();
        for (var i = 0; i < 100 && repository.sharedOpens == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(repository.sharedOpens, 1);
        ConnectivityService().simulateDisconnect();
        await vm.openManual();
        final manualId = c.read(currentOrderProvider).order!.id;
        if (openingFails) {
          repository.deferredSharedOpen!.completeError(
            TimeoutException('respuesta rápida perdida'),
          );
        } else {
          repository.deferredSharedOpen!.complete({'order_id': 'late-quick'});
        }
        await openingQuick;
        expect(c.read(currentOrderProvider).order?.id, manualId);
        expect(c.read(currentOrderProvider).origin, 'manual');
        expect(repository.loaded, isNot(contains('late-quick')));
        expect(
          (await offline.loadSnapshot(
            businessId: biz,
            slotId: 'manual',
          ))?.order?.id,
          manualId,
        );
      },
    );
  }

  test(
    'cerrar pestaña inactiva anula su venta y conserva el otro carrito',
    () async {
      const biz = 'close-inactive-retail';
      final one = sale('local-order-cart-one');
      final two = sale('local-order-cart-two');
      await offline.saveSnapshot(
        businessId: biz,
        slotId: 'quick-one',
        origin: 'quick',
        state: one,
      );
      await offline.saveSnapshot(
        businessId: biz,
        slotId: 'quick-two',
        origin: 'quick',
        state: two,
      );
      await enqueue(biz, one.order!.id);
      await enqueue(biz, two.order!.id);
      final c = container(biz, one, retail: true);
      c.read(retailCartsProvider.notifier).replaceAll([
        RetailCart(slotId: 'quick-one', number: 1, orderId: one.order!.id),
        RetailCart(slotId: 'quick-two', number: 2, orderId: two.order!.id),
      ], 'quick-one');
      // Asigna el slot interno mediante la ruta real de cambio de pestaña.
      await c.read(currentOrderProvider.notifier).switchRetailCart('quick-one');
      ConnectivityService().simulateDisconnect();
      await c.read(currentOrderProvider.notifier).closeRetailCart('quick-two');
      expect(c.read(retailCartsProvider).carts.map((v) => v.slotId), [
        'quick-one',
      ]);
      expect(c.read(currentOrderProvider).order?.id, one.order!.id);
      final queue = await offline.unsettledActions(biz);
      expect(queue.map((a) => a['order_id']), contains(one.order!.id));
      expect(queue.map((a) => a['order_id']), isNot(contains(two.order!.id)));
    },
  );

  test('leer snapshot no pisa un guardado concurrente más reciente', () async {
    const biz = 'snapshot-read-save-race';
    final old = sale('local-order-race', total: 100);
    final fresh = sale('local-order-race', total: 200);
    await offline.saveSnapshot(
      businessId: biz,
      slotId: 'quick',
      origin: 'quick',
      state: old,
    );
    final read = offline.loadSnapshot(businessId: biz, slotId: 'quick');
    await offline.saveSnapshot(
      businessId: biz,
      slotId: 'quick',
      origin: 'quick',
      state: fresh,
    );
    await read;
    expect(
      (await offline.loadSnapshot(
        businessId: biz,
        slotId: 'quick',
      ))?.order?.total,
      200,
    );
  });

  test(
    'operaciones muertas siguen protegiendo contenido local por ambos IDs',
    () async {
      const biz = 'dead-content-guard';
      final storage = await StorageService.getInstance();
      await storage.writeJson('offline_order_map_$biz', {
        'local-order-dead': 'remote-dead',
      });
      await offline.enqueueAction(
        businessId: biz,
        action: {
          'type': 'add_item',
          'status': 'dead',
          'order_id': 'local-order-dead',
        },
      );
      expect(
        await offline.hasUnsettledOrderActions(
          businessId: biz,
          orderId: 'remote-dead',
        ),
        isTrue,
      );
      expect(
        await offline.hasUnsettledOrderActions(
          businessId: biz,
          orderId: 'another-order',
        ),
        isFalse,
      );
    },
  );

  test('cierre local sigue siendo válido después del remap remoto', () async {
    const biz = 'closed-mapped-snapshot';
    final old = sale('local-order-closed');
    await offline.saveSnapshot(
      businessId: biz,
      slotId: 'quick',
      origin: 'quick',
      state: old,
    );
    final storage = await StorageService.getInstance();
    await storage.writeJson('offline_order_map_$biz', {
      'local-order-closed': 'remote-closed',
    });
    await offline.remapSnapshotOrderId(
      businessId: biz,
      localOrderId: 'local-order-closed',
      remoteOrderId: 'remote-closed',
    );
    await offline.markOrderClosedLocally(
      businessId: biz,
      orderId: 'local-order-closed',
    );
    expect(
      await offline.isOrderClosedLocally(
        businessId: biz,
        orderId: 'remote-closed',
      ),
      isTrue,
    );
    expect(
      await offline.loadSnapshot(businessId: biz, slotId: 'quick'),
      isNull,
    );
    await offline.saveSnapshot(
      businessId: biz,
      slotId: 'quick',
      origin: 'quick',
      state: old.copyWith(order: old.order!.copyWith(id: 'remote-closed')),
    );
    expect(
      await offline.loadSnapshot(businessId: biz, slotId: 'quick'),
      isNull,
    );
  });

  test(
    'dos deliveries offline conservan snapshots separados al editar cargo',
    () async {
      const biz = 'delivery-snapshot-isolation';
      await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
      for (final table in ['delivery-one', 'delivery-two']) {
        await offline.saveSnapshot(
          businessId: biz,
          slotId: table,
          tableId: table,
          origin: 'table',
          state: sale('local-order-$table').copyWith(origin: 'table'),
        );
      }
      final c = container(biz, const CurrentOrderState());
      ConnectivityService().simulateDisconnect();
      final vm = c.read(currentOrderProvider.notifier);
      await vm.openDeliveryOrder(tableId: 'delivery-one', deliveryType: 'own');
      await vm.setDeliveryFee(30);
      await vm.openDeliveryOrder(tableId: 'delivery-two', deliveryType: 'own');
      await vm.setDeliveryFee(50);
      final one = await offline.loadSnapshot(
        businessId: biz,
        slotId: 'delivery-one',
      );
      final two = await offline.loadSnapshot(
        businessId: biz,
        slotId: 'delivery-two',
      );
      expect(one?.order?.deliveryFee, 30);
      expect(two?.order?.deliveryFee, 50);
      expect(one?.order?.id, 'local-order-delivery-one');
      expect(two?.order?.id, 'local-order-delivery-two');
      expect(one?.origin, 'delivery');
      expect(two?.origin, 'delivery');
    },
  );
}
