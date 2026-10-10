import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_op_log.dart';
import 'package:mangopos/core/offline/hub/hub_op_log_dao.dart';
import 'package:mangopos/core/offline/hub/hub_state_db.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_dao.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HubStateDb hubDb;
  late OfflineQueueDb queueDb;
  late HubOpLog log;
  late OfflineQueueDao queue;
  final service = OfflinePosService();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    hubDb = HubStateDb.inMemory(NativeDatabase.memory());
    queueDb = OfflineQueueDb.inMemory(NativeDatabase.memory());
    HubStateDb.debugInstance = hubDb;
    OfflineQueueDb.debugInstance = queueDb;
    log = HubOpLog(dao: HubOpLogDao(hubDb));
    queue = OfflineQueueDao(queueDb);
  });

  tearDownAll(() async {
    await hubDb.close();
    await queueDb.close();
    HubStateDb.debugInstance = null;
  });

  test(
    'lectura pendiente conserva orden y excluye solo acuses durables',
    () async {
      const business = 'hub-closure-acks';
      for (final id in ['online', 'op-ack', 'fingerprint-ack', 'pending']) {
        await log.append(business, {
          'op_id': id,
          'type': 'add_item',
          'order_id': 'order-$id',
          'item_id': 'item-$id',
          if (id == 'online') 'hub_applied': true,
          if (id == 'fingerprint-ack') 'fingerprint': 'op:fingerprint-ack',
        });
      }
      await queue.markOpCompleted(businessId: business, opId: 'op-ack');
      await queue.markFingerprintCompleted(
        businessId: business,
        fingerprint: 'op:fingerprint-ack',
      );
      final actions = await service.unsettledHubActions(business);
      expect(actions.map((action) => action['op_id']), ['pending']);
      expect(actions.single['order_id'], 'order-pending');
      expect(actions.single['seq'], 4);
      expect(
        await log.length(business),
        4,
        reason: 'La conciliación lee; nunca descarta el journal.',
      );
      expect(
        () => actions.single['type'] = 'void_order',
        throwsUnsupportedError,
      );
    },
  );

  test(
    'registro ilegible impide afirmar que el Hub está sincronizado',
    () async {
      const business = 'hub-closure-corruption';
      await hubDb
          .into(hubDb.hubOps)
          .insert(
            HubOpsCompanion.insert(
              businessId: business,
              seq: 1,
              opId: const Value('unreadable-money-operation'),
              orderId: const Value('order-to-preserve'),
              payloadJson: 'invalid json',
              receivedAt: DateTime.utc(2026, 10, 9),
            ),
          );
      expect(service.unsettledHubActions(business), throwsStateError);
      expect(await log.length(business), 1);
    },
  );
}
