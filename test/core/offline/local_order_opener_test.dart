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

/// Mesa abierta sin red: al subir, la mesa real nace a nombre del mesero que
/// la abrió (PIN), no de la cuenta del equipo que sincroniza. Si no, la
/// precuenta y la factura salían con el nombre de quien tenía la sesión.
class _Sales extends SalesRepository {
  _Sales(super.client);
  final openedBy = <String?>[];

  @override
  Future<Map<String, dynamic>> openTable({
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    openedBy.add(openedByEmployeeId);
    return {'order_id': 'remote-order-${openedBy.length}'};
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

  Map<String, dynamic> openTable(String orderId) => {
    'type': 'open_table',
    'origin': 'table',
    'order_id': orderId,
    'table_id': 'table-1',
  };

  test('la mesa sube a nombre del mesero del PIN', () async {
    const biz = 'opener-pin';
    final draft = await service.createLocalDraft(
      businessId: biz,
      origin: 'table',
      tableId: 'table-1',
      opener: (employeeId: 'emp-claudia', name: 'Claudia'),
    );
    final localId = draft.order!.id;
    await service.enqueueAction(businessId: biz, action: openTable(localId));

    // Viaja en la acción: si la sube el Hub, él no tiene la anotación.
    final queued = await service.unsettledActions(biz);
    expect(queued.single['opened_by_employee_id'], 'emp-claudia');

    final result = await sync(biz);

    expect(result.completed, 1);
    expect(sales.openedBy, ['emp-claudia']);
    // Sin red, el «MESERO:» sale de aquí, por el id local o el remoto.
    final byLocal = await service.localOrderOpener(
      businessId: biz,
      orderId: localId,
    );
    final byRemote = await service.localOrderOpener(
      businessId: biz,
      orderId: 'remote-order-1',
    );
    expect(byLocal?.name, 'Claudia');
    expect(byRemote?.name, 'Claudia');
  });

  test('acción de otro equipo: usa el mesero que trae la acción', () async {
    const biz = 'opener-hub';
    await service.enqueueAction(
      businessId: biz,
      action: {
        ...openTable('local-order-de-otra-caja'),
        'opened_by_employee_id': 'emp-pedro',
      },
    );

    await sync(biz);

    expect(sales.openedBy, ['emp-pedro']);
  });

  test('sin PIN: sin empleado, y el nombre es el de quien la abrió', () async {
    const biz = 'opener-no-pin';
    final draft = await service.createLocalDraft(
      businessId: biz,
      origin: 'table',
      tableId: 'table-1',
      opener: (employeeId: null, name: 'Arianis'),
    );
    await service.enqueueAction(
      businessId: biz,
      action: openTable(draft.order!.id),
    );

    await sync(biz);

    expect(sales.openedBy, [null]);
    final opener = await service.localOrderOpener(
      businessId: biz,
      orderId: draft.order!.id,
    );
    expect(opener?.employeeId, isNull);
    expect(opener?.name, 'Arianis');
  });

  test('venta que este equipo no abrió sin red: no inventa nombre', () async {
    expect(
      await service.localOrderOpener(
        businessId: 'opener-none',
        orderId: 'remote-order-ajena',
      ),
      isNull,
    );
  });
}
