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

/// Replay del alta de ítem (cola cloud y op-log del Hub comparten el camino):
/// siempre con el client_op_id del toque original (20260929_0001).
class _Sales extends SalesRepository {
  _Sales(super.client);
  final opIds = <String>[];
  final modifierWrites = <String>[];
  bool serverSaysDeleted = false;

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
    opIds.add(clientOpId);
    return (
      itemId: 'remote-$clientOpId',
      replayed: serverSaysDeleted,
      itemExists: !serverSaysDeleted,
    );
  }

  @override
  Future<String> addItemFromMenu({
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
  }) => throw StateError('el replay no debe usar el alta sin client_op_id');

  @override
  Future<void> replaceOrderItemModifiers({
    required String itemId,
    required List<Map<String, dynamic>> modifiers,
  }) async {
    modifierWrites.add(itemId);
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

  Map<String, dynamic> addItem(String id, {String? clientOpId}) => {
    'id': id,
    'type': 'add_item',
    'origin': 'table',
    'order_id': '11111111-1111-1111-1111-111111111111',
    'item_id': 'tmp_$id',
    'menu_item_id': 'menu-1',
    'qty': 1,
    'client_op_id': ?clientOpId,
    'selected_modifiers': [
      {'name': 'Extra queso', 'qty': 1, 'price': 50},
    ],
  };

  test('usa el client_op_id del intento online, no uno nuevo', () async {
    const biz = 'replay-client-op';
    await service.enqueueAction(
      businessId: biz,
      action: addItem('a1', clientOpId: '7b0c4f7e-0000-4000-8000-000000000001'),
    );

    final result = await sync(biz);

    expect(result.completed, 1);
    expect(sales.opIds, ['7b0c4f7e-0000-4000-8000-000000000001']);
    expect(sales.modifierWrites, [
      'remote-7b0c4f7e-0000-4000-8000-000000000001',
    ]);
  });

  test(
    'acción de un build viejo (sin client_op_id): id DETERMINISTA por acción',
    () async {
      final a = OfflinePosService.addItemClientOpId(addItem('legacy-1'));
      final again = OfflinePosService.addItemClientOpId(addItem('legacy-1'));
      final other = OfflinePosService.addItemClientOpId(addItem('legacy-2'));

      expect(a, again, reason: 'dos replays de la misma acción = un ítem');
      expect(a, isNot(other), reason: 'dos toques = dos ítems');
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(a),
        isTrue,
        reason: 'debe ser un uuid válido para la columna uuid del servidor',
      );

      const biz = 'replay-legacy-op';
      await service.enqueueAction(businessId: biz, action: addItem('legacy-1'));
      await sync(biz);
      expect(sales.opIds, [a]);
    },
  );

  test(
    'el ítem ya se creó y se borró: no re-aplica extras y la acción se salda',
    () async {
      const biz = 'replay-deleted-item';
      sales.serverSaysDeleted = true;
      await service.enqueueAction(
        businessId: biz,
        action: addItem(
          'd1',
          clientOpId: '7b0c4f7e-0000-4000-8000-000000000002',
        ),
      );

      final result = await sync(biz);

      expect(result.completed, 1);
      expect(result.failed, 0);
      expect(sales.modifierWrites, isEmpty);
      expect(await service.pendingActionsCount(biz), 0);
    },
  );
}
