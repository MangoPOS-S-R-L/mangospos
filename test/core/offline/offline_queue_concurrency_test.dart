import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  late OfflineQueueDb db;
  late SupabaseClient client;
  late ProbeInventory inventory;
  late SalesRepository sales;
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
    sales = SalesRepository(client);
  });
  tearDownAll(() async {
    await db.close();
    await client.dispose();
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
    'sync preserves an action enqueued while the RPC is in flight',
    () async {
      const biz = 'audit-race';
      await enqueueCount(biz, 'old-op', 5);
      final entered = Completer<void>();
      final release = Completer<void>();
      inventory.duringReplay = () async {
        entered.complete();
        await release.future;
      };
      final runningSync = sync(biz);
      await entered.future;
      await enqueueCount(biz, 'new-op', 9);
      expect(
        (await service.unsettledActions(biz)).map((a) => a['id']),
        contains('new-op'),
      );
      release.complete();
      final result = await runningSync;
      expect(result.pending, 1);
      inventory.duringReplay = null;
      final rows = await db.select(db.queueActions).get();
      expect(
        rows.where((r) => r.businessId == biz).map((r) => r.id),
        contains('new-op'),
      );
    },
  );

  test(
    'separate kitchen rounds keep FIFO and their own delivery state',
    () async {
      const biz = 'kitchen-rounds';
      for (final action in <Map<String, dynamic>>[
        {
          'id': 'add-first',
          'type': 'add_item',
          'order_id': 'table-order',
          'item_id': 'tmp_first',
        },
        {
          'id': 'send-first',
          'type': 'confirm_local_order',
          'order_id': 'table-order',
          'printed_areas': [],
          'missing_areas': ['kitchen'],
        },
        {
          'id': 'add-second',
          'type': 'add_item',
          'order_id': 'table-order',
          'item_id': 'tmp_second',
        },
        {
          'id': 'send-second',
          'type': 'confirm_local_order',
          'order_id': 'table-order',
          'printed_areas': ['kitchen'],
          'missing_areas': [],
        },
      ]) {
        await service.enqueueAction(businessId: biz, action: action);
      }
      final actions = await service.unsettledActions(biz);
      expect(actions.map((a) => a['id']), [
        'add-first',
        'send-first',
        'add-second',
        'send-second',
      ]);
      expect(actions[1]['missing_areas'], ['kitchen']);
      expect(actions[3]['printed_areas'], ['kitchen']);
    },
  );

  test('parallel enqueues preserve every acknowledged action', () async {
    const biz = 'parallel-enqueue';
    await Future.wait(
      List.generate(20, (i) => enqueueCount(biz, 'parallel-$i', i.toDouble())),
    );
    final actions = await service.unsettledActions(biz);
    expect(actions, hasLength(20));
    expect(actions.map((a) => a['id']).toSet(), hasLength(20));
  });

  test('distinct inventory counts are both replayed; same op is not', () async {
    const biz = 'distinct-intentions';
    inventory.counts.clear();
    await enqueueCount(biz, 'count-five', 5);
    await sync(biz);
    await enqueueCount(biz, 'count-nine', 9);
    await sync(biz);
    await enqueueCount(biz, 'count-nine', 9);
    await sync(biz);
    expect(inventory.counts, [5, 9]);
    expect(await service.unsettledActions(biz), isEmpty);
  });
}
