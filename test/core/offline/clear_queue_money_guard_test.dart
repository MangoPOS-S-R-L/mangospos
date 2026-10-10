// «Limpiar cola…» nunca descarta dinero: cobros, caja y todo lo de una cuenta
// con un cobro pendiente (por id local o remoto) se conservan. Lo que sí
// descarta queda respaldado (cifrado) en el equipo antes de borrarlo.

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
  late OfflineQueueDb db;
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
  });

  tearDownAll(() => db.close());

  Future<void> enqueue(String biz, Map<String, dynamic> action) =>
      service.enqueueAction(businessId: biz, action: action);

  Future<List<String>> queuedTypes(String biz) async =>
      (await service.unsettledActions(biz))
          .map((a) => '${a['type']}:${a['order_id'] ?? '-'}')
          .toList();

  test('conserva cobros, caja y las cuentas con cobro; respalda lo demás',
      () async {
    const biz = 'clear-guard';
    final storage = await StorageService.getInstance();
    // La cuenta A ya subió: sus acciones viejas usan el id local y las
    // nuevas el remoto. El cobro (con el id local) protege ambas.
    await storage.writeJson('offline_order_map_$biz', {
      'local-order-a': 'remote-a',
    });
    await enqueue(biz, {
      'type': 'add_item',
      'order_id': 'local-order-a',
      'menu_item_id': 'm1',
      'quantity': 1,
    });
    await enqueue(biz, {
      'type': 'update_item_notes',
      'order_id': 'remote-a',
      'item_id': 'i1',
      'notes': 'sin sal',
    });
    await enqueue(biz, {
      'type': 'process_payment',
      'order_id': 'local-order-a',
      'amount': 100,
    });
    await enqueue(biz, {
      'type': 'cash_transaction',
      'amount': 50,
      'kind': 'out',
    });
    await enqueue(biz, {
      'type': 'add_item',
      'order_id': 'local-order-b',
      'menu_item_id': 'm2',
      'quantity': 2,
    });
    await enqueue(biz, {
      'type': 'update_item_notes',
      'order_id': 'remote-c',
      'item_id': 'i9',
      'notes': 'x',
    });

    final preview = await service.previewClearPendingActions(biz);
    expect(preview.discardable, 2);
    expect(preview.kept, 4);

    final deleted = await service.clearPendingActions(
      biz,
      discardedBy: 'Cajero 1',
    );

    expect(deleted, 2);
    expect(await queuedTypes(biz), unorderedEquals([
      'add_item:local-order-a',
      'update_item_notes:remote-a',
      'process_payment:local-order-a',
      'cash_transaction:-',
    ]));
    final backup = await service.discardedActionsBackup(biz);
    expect(
      backup.map((a) => '${a['type']}:${a['order_id']}'),
      unorderedEquals(['add_item:local-order-b', 'update_item_notes:remote-c']),
    );
    expect(backup.every((a) => a['discarded_by'] == 'Cajero 1'), isTrue);
    expect(backup.every((a) => a['business_id'] == biz), isTrue);
    expect(backup.every((a) => a['discarded_at'] != null), isTrue);
    expect(backup.first['menu_item_id'] ?? backup.last['menu_item_id'], 'm2',
        reason: 'el payload completo queda en el respaldo');

    // Segundo uso: el respaldo acumula, no reemplaza.
    await enqueue(biz, {
      'type': 'add_item',
      'order_id': 'local-order-d',
      'menu_item_id': 'm3',
      'quantity': 1,
    });
    expect(await service.clearPendingActions(biz), 1);
    expect(await service.discardedActionsBackup(biz), hasLength(3));
  });

  test('el respaldo no tiene tope: más de 500 descartes se conservan todos',
      () async {
    const biz = 'clear-guard-no-cap';
    for (var round = 0; round < 2; round++) {
      for (var i = 0; i < 260; i++) {
        await enqueue(biz, {
          'type': 'add_item',
          'order_id': 'local-order-$round-$i',
          'menu_item_id': 'm',
          'quantity': 1,
        });
      }
      expect(await service.clearPendingActions(biz), 260);
    }

    final backup = await service.discardedActionsBackup(biz);
    expect(backup, hasLength(520));
    expect(backup.first['order_id'], 'local-order-0-0',
        reason: 'lo más viejo sigue ahí y sale primero');
    expect(backup.last['order_id'], 'local-order-1-259');
  });

  test('solo dinero pendiente: no descarta nada', () async {
    const biz = 'clear-guard-money-only';
    await enqueue(biz, {
      'type': 'process_payment',
      'order_id': 'remote-z',
      'amount': 10,
    });
    await enqueue(biz, {'type': 'open_cash_session', 'opening_amount': 0});

    final preview = await service.previewClearPendingActions(biz);
    expect(preview.discardable, 0);
    expect(preview.kept, 2);
    expect(await service.clearPendingActions(biz), 0);
    expect(await service.pendingActionsCount(biz), 2);
    expect(await service.discardedActionsBackup(biz), isEmpty);
  });
}
