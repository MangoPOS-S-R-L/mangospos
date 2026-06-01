import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/storage/offline_queue_dao.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';

/// G9b: el `payloadJson` de la cola se guarda CIFRADO (AES-GCM) y se
/// recupera transparente. Las columnas estructuradas quedan en claro.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock del canal de flutter_secure_storage (clave del SecureBlobCipher).
  const channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'write':
          secureStore[args['key'] as String] = args['value'] as String;
          return null;
        case 'read':
          return secureStore[args['key'] as String];
        case 'delete':
          secureStore.remove(args['key']);
          return null;
        case 'containsKey':
          return secureStore.containsKey(args['key']);
        case 'readAll':
          return Map<String, String>.from(secureStore);
        case 'deleteAll':
          secureStore.clear();
          return null;
      }
      return null;
    });
  });

  late OfflineQueueDb db;
  late OfflineQueueDao dao;

  setUp(() {
    db = OfflineQueueDb.inMemory(NativeDatabase.memory());
    dao = OfflineQueueDao(db);
  });
  tearDown(() async => db.close());

  test('payload se cifra en disco y el round-trip preserva los datos',
      () async {
    await dao.upsertAction('biz-1', {
      'id': 'op1',
      'type': 'process_payment',
      'order_id': 'o1',
      'amount': 1588.01,
      'customer_rnc': '101000001',
      'queued_at': '2026-06-01T00:00:00.000Z',
    });

    // Round-trip: los datos sensibles vuelven intactos.
    final back = await dao.readQueue('biz-1');
    expect(back.length, 1);
    expect(back.single['amount'], 1588.01);
    expect(back.single['order_id'], 'o1');
    expect(back.single['customer_rnc'], '101000001');
    expect(back.single['type'], 'process_payment'); // columna estructurada

    // En disco, el payloadJson está cifrado (sobre enc:v1:), no en claro.
    final row = await db.select(db.queueActions).getSingle();
    expect(row.payloadJson.startsWith('enc:v1:'), isTrue);
    expect(row.payloadJson.contains('101000001'), isFalse);
    expect(row.type, 'process_payment'); // estructurada en claro
  });

  test('lee filas legacy con payload en texto plano (migración perezosa)',
      () async {
    // Insert directo con payload en texto plano (como pre-G9b).
    await db.into(db.queueActions).insert(
          QueueActionsCompanion.insert(
            id: 'legacy1',
            businessId: 'biz-1',
            type: 'add_item',
            payloadJson: '{"order_id":"oLegacy","qty":3}',
            queuedAt: DateTime.parse('2026-06-01T00:00:00.000Z'),
          ),
        );
    final back = await dao.readQueue('biz-1');
    expect(back.single['order_id'], 'oLegacy');
    expect(back.single['qty'], 3);
  });
}
