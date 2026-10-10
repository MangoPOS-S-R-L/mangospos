import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  final service = OfflinePosService();
  late OfflineQueueDb db;

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
    service.setHubUploader(null);
  });

  tearDownAll(() async {
    await db.close();
  });

  Future<void> seedPayment(
    String businessId, {
    required String status,
    required String paymentOrderId,
    String type = 'process_payment',
  }) async {
    final storage = await StorageService.getInstance();
    await storage.writeJson('offline_order_map_$businessId', {
      'local-order-one': 'remote-order-one',
      'local-order-alias': 'remote-order-one',
      'local-order-other': 'remote-order-other',
    });
    await service.enqueueAction(
      businessId: businessId,
      action: {
        'id': 'payment-$businessId',
        'type': type,
        'status': status,
        'order_id': paymentOrderId,
        'amount': 150,
      },
    );
  }

  for (final status in ['pending', 'processing', 'failed', 'dead']) {
    test('$status local payment protects every alias of its order', () async {
      final businessId = 'local-payment-alias-$status';
      await seedPayment(
        businessId,
        status: status,
        paymentOrderId: 'local-order-one',
      );
      for (final orderId in [
        'local-order-one',
        'remote-order-one',
        'local-order-alias',
      ]) {
        expect(
          await service.hasQueuedPayment(
            businessId: businessId,
            orderId: orderId,
          ),
          isTrue,
          reason: 'El dinero pendiente debe proteger $orderId.',
        );
      }
      expect(
        await service.hasQueuedPayment(
          businessId: businessId,
          orderId: 'remote-order-other',
        ),
        isFalse,
      );
    });
  }

  test('remote queued payment protects a restored local order', () async {
    const businessId = 'remote-payment-alias';
    await seedPayment(
      businessId,
      status: 'failed',
      paymentOrderId: 'remote-order-one',
    );
    expect(
      await service.hasQueuedPayment(
        businessId: businessId,
        orderId: 'local-order-one',
      ),
      isTrue,
    );
    expect(
      await service.hasQueuedPayment(
        businessId: 'another-business',
        orderId: 'remote-order-one',
      ),
      isFalse,
    );
  });

  for (final scenario in [
    (status: 'completed', type: 'process_payment'),
    (status: 'failed', type: 'add_item'),
  ]) {
    test('${scenario.status} ${scenario.type} does not block', () async {
      final businessId = 'settled-alias-${scenario.type}';
      await seedPayment(
        businessId,
        status: scenario.status,
        type: scenario.type,
        paymentOrderId: 'local-order-one',
      );
      expect(
        await service.hasQueuedPayment(
          businessId: businessId,
          orderId: 'remote-order-one',
        ),
        isFalse,
      );
    });
  }
}
