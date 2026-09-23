import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/sales_models.dart';
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
}
