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

/// Caso MESA4 (Food Shop, 10-oct): una cuenta tomada sin conexión se subía
/// con `openTable(mesa)`, que devuelve la cuenta ABIERTA ACTUAL de la mesa:
/// sus productos se sumaban a la que otro mesero ya había vuelto a teclear.
/// Ahora sube con SU identidad (`fn_open_local_table_order`, 20261010_0020):
/// el servidor la reencuentra en un reintento y, si la mesa ya tiene otra
/// cuenta con productos, la guarda aparte en revisión.
class _Sales extends SalesRepository {
  _Sales(super.client);

  final opened = <({String clientOrderId, String tableId})>[];
  var failNext = false;
  var openTableCalls = 0;

  @override
  Future<Map<String, dynamic>> openLocalTableOrder({
    required String clientOrderId,
    required String tableId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    opened.add((clientOrderId: clientOrderId, tableId: tableId));
    if (failNext) {
      failNext = false;
      // Respuesta perdida: el servidor pudo haberla creado igual.
      throw Exception('SocketException: Connection reset by peer');
    }
    return {
      'order_id': 'review-order-1',
      'session_id': 'session-de-la-mesa',
      'outcome': 'review',
      'review': true,
    };
  }

  @override
  Future<Map<String, dynamic>> openTable({
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    openTableCalls++;
    throw StateError('Una cuenta local no se sube por la mesa');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  late OfflineQueueDb db;
  late SupabaseClient client;
  late _Sales sales;
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
    client = SupabaseClient('http://localhost:54321', 'test-key');
  });

  tearDownAll(() async {
    await db.close();
    await client.dispose();
  });

  setUp(() {
    service.setHubUploader(null);
    sales = _Sales(client);
  });

  Future<OfflineQueueSyncResult> sync(String biz) => service.syncPendingActions(
    businessId: biz,
    salesRepository: sales,
    printingService: PrintingService(client),
    inventoryRepository: InventoryRepository(client),
    cashierRepository: CashierRepository(client),
    force: true,
  );

  Future<String> queueLocalTable(String biz) async {
    final draft = await service.createLocalDraft(
      businessId: biz,
      origin: 'table',
      tableId: 'mesa-4',
    );
    final localId = draft.order!.id;
    await service.enqueueAction(
      businessId: biz,
      action: {
        'type': 'open_table',
        'origin': 'table',
        'order_id': localId,
        'table_id': 'mesa-4',
      },
    );
    return localId;
  }

  test(
    'la cuenta local sube con SU identidad, no como «la cuenta de la mesa»',
    () async {
      const biz = 'identity-mesa4';
      final localId = await queueLocalTable(biz);

      final result = await sync(biz);

      expect(result.completed, 1);
      expect(sales.openTableCalls, 0);
      expect(sales.opened, [(clientOrderId: localId, tableId: 'mesa-4')]);
      // La cola sigue con la cuenta que devolvió el servidor (aquí, la de
      // revisión): sus productos van a ESA cuenta, no a la retecleada.
      expect(
        await service.mappedRemoteOrderId(
          businessId: biz,
          localOrderId: localId,
        ),
        'review-order-1',
      );
    },
  );

  test('respuesta perdida: el reintento usa la MISMA identidad', () async {
    const biz = 'identity-retry';
    final localId = await queueLocalTable(biz);
    sales.failNext = true;

    await sync(biz);
    expect(
      await service.mappedRemoteOrderId(businessId: biz, localOrderId: localId),
      isNull,
    );

    await sync(biz);

    expect(sales.opened.map((o) => o.clientOrderId), [localId, localId]);
    expect(
      await service.mappedRemoteOrderId(businessId: biz, localOrderId: localId),
      'review-order-1',
    );
    expect(sales.openTableCalls, 0);
  });
}
