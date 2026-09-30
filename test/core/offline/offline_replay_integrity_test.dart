import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/models/order_item_tax_line.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProbeInventory extends InventoryRepository {
  ProbeInventory(super.client);
  final counts = <double>[];
  Future<void> Function()? duringReplay;

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
    counts.add(countedQuantity);
    await duringReplay?.call();
  }
}

class ProbeSales extends SalesRepository {
  ProbeSales(super.client);
  final calls = <Map<String, dynamic>>[];
  int addedItems = 0;
  int modifierWrites = 0;
  bool failModifiers = false;
  bool failKitchen = false;
  final deleted = <String>[];
  final quantities = <String>[];
  final kitchenStates = <String>[];

  @override
  Future<String> addItemFromMenu({
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
  }) async {
    addedItems++;
    return 'remote-item-$addedItems';
  }

  /// client_op_id recibidos por el alta idempotente, en orden.
  final clientOpIds = <String>[];

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
    clientOpIds.add(clientOpId);
    final id = await addItemFromMenu(
      orderId: orderId,
      menuItemId: menuItemId,
      quantity: quantity,
      checkPosition: checkPosition,
      isTakeout: isTakeout,
      notes: notes,
    );
    return (itemId: id, replayed: false, itemExists: true);
  }

  @override
  Future<void> replaceOrderItemModifiers({
    required String itemId,
    required List<Map<String, dynamic>> modifiers,
  }) async {
    modifierWrites++;
    if (failModifiers) throw StateError('modifier dependency unavailable');
  }

  @override
  Future<void> deleteItem({required String itemId}) async {
    deleted.add(itemId);
  }

  @override
  Future<void> noteItemRemoval({
    required String itemId,
    String? reason,
    String? employeeId,
    String? reasonCode,
    bool? isWaste,
  }) async {}

  @override
  Future<void> updateItemQuantity({
    required String itemId,
    required double quantity,
  }) async {
    quantities.add(itemId);
  }

  @override
  Future<void> updateOfflineKitchenItemStatus({
    required String itemId,
    required String status,
    required DateTime at,
  }) async {
    kitchenStates.add(status);
    if (failKitchen) throw TimeoutException('kitchen network unavailable');
  }

  @override
  Future<Payment> processPayment({
    required String orderId,
    String? checkId,
    required String paymentMethodId,
    required double amount,
    String? reference,
    String? customerId,
    String? customerRnc,
    String? fiscalType,
    String? cashierSessionId,
    double changeAmount = 0,
    bool closeOrder = true,
    bool closeCheck = true,
    int splitSequence = 0,
    DateTime? paidAt,
    String? offlineNcf,
  }) async {
    calls.add({
      'split': splitSequence,
      'close': closeOrder,
      'close_check': closeCheck,
      'amount': amount,
    });
    // Stop at the repository boundary after observing the actual replay args.
    throw StateError('audit probe: no real payment executed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  late OfflineQueueDb db;
  late SupabaseClient client;
  late ProbeInventory inventory;
  late ProbeSales sales;
  final service = OfflinePosService();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
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
    client = SupabaseClient('http://localhost:54321', 'audit-dummy-key');
    inventory = ProbeInventory(client);
    sales = ProbeSales(client);
  });
  tearDownAll(() async {
    await db.close();
    await client.dispose();
  });

  setUp(() {
    service.setHubUploader(null);
    sales.calls.clear();
    sales.addedItems = 0;
    sales.clientOpIds.clear();
    sales.modifierWrites = 0;
    sales.failModifiers = false;
    sales.failKitchen = false;
    sales.deleted.clear();
    sales.quantities.clear();
    sales.kitchenStates.clear();
  });

  Future<void> enqueueCount(String biz, String id, double count) =>
      service.enqueueAction(
        businessId: biz,
        action: {
          'id': id,
          'type': 'inventory_adjust',
          'warehouse_id': 'warehouse',
          'item_id': 'same-item',
          'counted_quantity': count,
          'reason_code': 'correction',
        },
      );

  Future<OfflineQueueSyncResult> sync(String biz) => service.syncPendingActions(
    businessId: biz,
    salesRepository: sales,
    printingService: PrintingService(client),
    inventoryRepository: inventory,
    cashierRepository: CashierRepository(client),
    force: true,
  );

  test(
    'LAN recovery forwards the durable queue in order without cloud',
    () async {
      const biz = 'lan-recovery';
      await enqueueCount(biz, 'one', 1);
      await enqueueCount(biz, 'two', 2);
      final received = <String>[];
      service.setHubUploader((_, op) async {
        // It is already durable while the network request is in flight.
        expect(await service.pendingActionsCount(biz), greaterThan(0));
        received.add(op['id'] as String);
        return received.length;
      });
      final result = await service.flushPendingToHub(biz);
      expect(received, ['one', 'two']);
      expect(result.completed, 2);
      expect(result.pending, 0);
      service.setHubUploader(null);
    },
  );

  test(
    'disk snapshot restores modifiers and fiscal detail, not just totals',
    () async {
      final at = DateTime.utc(2026, 9, 29);
      final item = OrderItem(
        id: 'tmp_snapshot',
        orderId: 'local-order-snapshot',
        productName: 'Cafe',
        quantity: 1,
        unitPrice: 100,
        subtotal: 110,
        discounts: 0,
        tax: 19.8,
        total: 129.8,
        createdAt: at,
        taxRate: 18,
        originalTaxRate: 18,
        isTakeout: false,
        status: 'draft',
        modifiers: const [
          OrderItemModifier(
            id: 'm',
            itemId: 'tmp_snapshot',
            name: 'Extra',
            qty: 1,
            price: 10,
          ),
        ],
        taxLines: [
          OrderItemTaxLine(
            id: 't',
            orderItemId: 'tmp_snapshot',
            taxId: 'itbis',
            taxName: 'ITBIS',
            taxRate: 18,
            amount: 19.8,
            createdAt: at,
          ),
        ],
      );
      final order = Order(
        id: item.orderId,
        sessionId: 'local-session-snapshot',
        status: 'open',
        subtotal: 110,
        discounts: 0,
        serviceFee: 0,
        tax: 19.8,
        total: 129.8,
        createdAt: at,
      );
      await service.saveSnapshot(
        businessId: 'snapshot-test',
        slotId: 'table',
        origin: 'table',
        state: CurrentOrderState(order: order, items: [item]),
      );
      final restored = await service.loadSnapshot(
        businessId: 'snapshot-test',
        slotId: 'table',
      );
      expect(restored!.items.single, item);
    },
  );

  test(
    'lost Hub reply retries same ID; does not replay against cloud',
    () async {
      const biz = 'lan-lost-ack';
      await enqueueCount(biz, 'lost-ack', 3);
      final ids = <String>[];
      service.setHubUploader((_, op) async {
        ids.add(op['id'] as String);
        return null;
      });
      await service.flushPendingToHub(biz);
      service.setHubUploader(null);
      final before = inventory.counts.length;
      await sync(biz);
      expect(inventory.counts.length, before);
      expect(await service.pendingActionsCount(biz), 1);
      service.setHubUploader((_, op) async {
        ids.add(op['id'] as String);
        return 1;
      });
      await service.flushPendingToHub(biz);
      expect(ids, ['lost-ack', 'lost-ack']);
      expect(await service.pendingActionsCount(biz), 0);
      service.setHubUploader(null);
    },
  );

  test('possibly delivered item is never compacted away by a delete', () async {
    const biz = 'lan-no-compact';
    await service.enqueueAction(
      businessId: biz,
      action: {
        'id': 'add-lan',
        'type': 'add_item',
        'order_id': 'local-order-lan',
        'item_id': 'tmp_lan',
        'qty': 1,
      },
    );
    service.setHubUploader((_, _) async => null);
    await service.flushPendingToHub(biz);
    service.setHubUploader(null);
    await service.enqueueAction(
      businessId: biz,
      action: {
        'id': 'delete-lan',
        'type': 'delete_item',
        'order_id': 'local-order-lan',
        'item_id': 'tmp_lan',
      },
    );
    final received = <String>[];
    service.setHubUploader((_, op) async {
      received.add(op['id'] as String);
      return received.length;
    });
    await service.flushPendingToHub(biz);
    expect(received, ['add-lan', 'delete-lan']);
    service.setHubUploader(null);
  });

  test(
    'partially uploaded cloud order does not block unrelated LAN orders',
    () async {
      const biz = 'mixed-authorities';
      sales.failModifiers = true;
      await service.enqueueAction(
        businessId: biz,
        action: {
          'id': 'cloud-add',
          'type': 'add_item',
          'order_id': 'existing-cloud-order',
          'item_id': 'tmp_cloud',
          'menu_item_id': 'p',
          'qty': 1,
          'selected_modifiers': [
            {'name': 'Extra', 'qty': 1, 'price': 10},
          ],
        },
      );
      await sync(biz);
      await service.enqueueAction(
        businessId: biz,
        action: {
          'id': 'cloud-delete',
          'type': 'delete_item',
          'order_id': 'existing-cloud-order',
          'item_id': 'tmp_cloud',
        },
      );
      await service.enqueueAction(
        businessId: biz,
        action: {
          'id': 'new-table',
          'type': 'open_table',
          'order_id': 'local-order-new',
          'table_id': 'new-table',
        },
      );
      final forwarded = <String>[];
      service.setHubUploader((_, op) async {
        forwarded.add(op['id'] as String);
        return forwarded.length;
      });
      final result = await service.flushPendingToHub(biz);
      expect(forwarded, ['new-table']);
      expect(result.pending, 2);
      expect(result.lastError, isNotNull);
      service.setHubUploader(null);
    },
  );

  test('split replay preserves sequence and both close flags', () async {
    const biz = 'audit-split';
    await service.enqueueAction(
      businessId: biz,
      action: {
        'id': 'split-second',
        'type': 'process_payment',
        'order_id': 'existing-remote-order',
        'payment_method_id': 'cash',
        'amount': 100,
        'split_sequence': 1,
        'close_order': false,
        'close_check': false,
      },
    );
    await sync(biz);
    expect(sales.calls.single, {
      'split': 1,
      'close': false,
      'close_check': false,
      'amount': 100.0,
    });
  });

  test(
    'failed inventory upload remains pending with its original operation ID',
    () async {
      const biz = 'audit-inventory-network-failure';
      var attempted = 0;
      final failingClient = SupabaseClient(
        'http://localhost:54321',
        'audit-dummy-key',
        httpClient: MockClient((_) async {
          attempted++;
          throw TimeoutException('simulated network timeout');
        }),
      );
      try {
        await enqueueCount(biz, 'never-reached-server', 12);
        final result = await service.syncPendingActions(
          businessId: biz,
          salesRepository: sales,
          printingService: PrintingService(client),
          inventoryRepository: InventoryRepository(failingClient),
          cashierRepository: CashierRepository(client),
          force: true,
        );
        expect(attempted, greaterThan(0));
        expect(result.completed, 0);
        expect(result.failed, 1);
        expect(result.pending, 1);
        final pending = await service.unsettledActions(biz);
        expect(pending, hasLength(1));
        expect(pending.single['id'], 'never-reached-server');
      } finally {
        await failingClient.dispose();
      }
    },
  );

  test(
    'missing local identity never updates or deletes an unrelated item',
    () async {
      const biz = 'item-identity-audit';
      for (final type in ['delete_item', 'update_item_quantity']) {
        await service.enqueueAction(
          businessId: biz,
          action: {
            'id': type,
            'type': type,
            'order_id': 'remote-order-$type',
            'item_id': 'tmp_missing_$type',
            'quantity': 2,
          },
        );
      }
      final result = await sync(biz);
      expect(result.failed, 2);
      expect(result.completed, 0);
      expect(sales.deleted, isEmpty);
      expect(sales.quantities, isEmpty);
      expect(await service.unsettledActions(biz), hasLength(2));
    },
  );

  test(
    'failed modifiers block payment and retry reuses the created item',
    () async {
      const biz = 'item-modifier-audit';
      sales.failModifiers = true;
      await service.enqueueAction(
        businessId: biz,
        action: {
          'id': 'add-with-extra',
          'type': 'add_item',
          'order_id': 'remote-order',
          'item_id': 'tmp_extra',
          'menu_item_id': 'product',
          'qty': 1,
          'selected_modifiers': [
            {'name': 'Extra', 'qty': 1, 'price': 25},
          ],
        },
      );
      await service.enqueueAction(
        businessId: biz,
        action: {
          'id': 'pay-with-extra',
          'type': 'process_payment',
          'order_id': 'remote-order',
          'payment_method_id': 'cash',
          'amount': 125,
        },
      );
      await service.enqueueAction(
        businessId: biz,
        action: {
          'id': 'unrelated-delete',
          'type': 'delete_item',
          'order_id': 'other-order',
          'item_id': 'other-real-item',
        },
      );
      final first = await sync(biz);
      expect(first.failed, 1);
      expect(first.skipped, 1);
      expect(sales.calls, isEmpty);
      expect(sales.deleted, ['other-real-item']);
      expect(sales.addedItems, 1);
      sales.failModifiers = false;
      await sync(biz);
      expect(sales.addedItems, 1, reason: 'do not insert the same item again');
      expect(sales.modifierWrites, 2);
      expect(sales.calls, hasLength(1));
    },
  );

  test(
    'KDS target state survives queue processing and network retries',
    () async {
      const biz = 'kds-state-audit';
      sales.failKitchen = true;
      await service.enqueueAction(
        businessId: biz,
        action: {
          'id': 'kds-ready',
          'type': 'kds_item_status',
          'item_id': 'real-kitchen-item',
          'status': 'ready',
        },
      );
      final first = await sync(biz);
      expect(first.failed, 1);
      final queued = (await service.unsettledActions(biz)).single;
      expect(queued['kds_status'], 'ready');
      expect(queued['status'], 'failed');
      sales.failKitchen = false;
      final second = await sync(biz);
      expect(second.completed, 1);
      expect(sales.kitchenStates, ['ready', 'ready']);
    },
  );

  test(
    'deleting a partially uploaded item does not erase its pending add',
    () async {
      const biz = 'partial-item-delete-audit';
      sales.failModifiers = true;
      await service.enqueueAction(
        businessId: biz,
        action: {
          'id': 'partial-add',
          'type': 'add_item',
          'order_id': 'remote-order',
          'item_id': 'tmp_partial',
          'menu_item_id': 'product',
          'qty': 1,
          'selected_modifiers': [
            {'name': 'Extra', 'price': 20},
          ],
        },
      );
      await sync(biz);
      await service.enqueueAction(
        businessId: biz,
        action: {
          'id': 'partial-delete',
          'type': 'delete_item',
          'order_id': 'remote-order',
          'item_id': 'tmp_partial',
        },
      );
      expect(await service.unsettledActions(biz), hasLength(2));
      sales.failModifiers = false;
      final result = await sync(biz);
      expect(result.completed, 2);
      expect(sales.addedItems, 1);
      expect(sales.deleted, ['remote-item-1']);
    },
  );
}
