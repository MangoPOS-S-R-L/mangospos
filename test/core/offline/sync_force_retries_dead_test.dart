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

/// Dead-letter y el botón "Sincronizar ahora":
/// - Una acción que agota [OfflinePosService.maxAttempts] con error de
///   negocio (no-conectividad) pasa a `dead`.
/// - El sync automático (force: false) la salta — no reintenta sola.
/// - El sync manual (force: true) SÍ la reintenta: si la causa raíz se
///   corrigió, completa y sale de la cola. Antes el manual también la
///   saltaba y el cajero solo tenía "Limpiar cola" (perdiendo la venta).
/// - `unsettledActions` expone estado y `last_error` para el visor.
class _FakeInventoryRepo extends InventoryRepository {
  _FakeInventoryRepo(super.client);

  bool succeed = false;
  int calls = 0;

  @override
  Future<void> adjustInventory({
    required String businessId,
    required String warehouseId,
    required String itemId,
    required double countedQuantity,
    required String reasonCode,
    String? notes,
    double? costPerUnit,
  }) async {
    calls++;
    if (!succeed) {
      throw Exception('violates check constraint "qty_positive"');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock del canal de flutter_secure_storage (clave del SecureBlobCipher
  // que cifra los payloads de la cola).
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
    // La conexión drift real necesita path_provider (no existe en tests);
    // inyectamos una DB en memoria ANTES de que el service la toque.
    OfflineQueueDb.debugInstance =
        OfflineQueueDb.inMemory(NativeDatabase.memory());
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // Cliente dummy: los fakes no llegan a usarlo y el resto de repos no se
  // invoca para el tipo de acción de este test. Se construye en setUpAll
  // porque SupabaseClient crea un HttpClient, que solo puede instanciarse
  // dentro de la zona de test.
  final svc = OfflinePosService();
  late final _FakeInventoryRepo inventory;
  late final SalesRepository sales;
  late final PrintingService printing;
  late final CashierRepository cashier;
  setUpAll(() {
    final client =
        SupabaseClient('http://localhost:54321', 'test-anon-key');
    inventory = _FakeInventoryRepo(client);
    sales = SalesRepository(client);
    printing = PrintingService(client);
    cashier = CashierRepository(client);
  });

  Future<OfflineQueueSyncResult> sync(String biz, {required bool force}) =>
      svc.syncPendingActions(
        businessId: biz,
        salesRepository: sales,
        printingService: printing,
        inventoryRepository: inventory,
        cashierRepository: cashier,
        force: force,
      );

  test('dead-letter: el sync automático la salta, el manual la reintenta',
      () async {
    const biz = 'biz-dead-retry';
    await svc.enqueueAction(businessId: biz, action: {
      'type': 'inventory_adjust',
      'warehouse_id': 'w1',
      'item_id': 'i1',
      'counted_quantity': 5,
      'reason_code': 'correction',
    });

    // Agota los reintentos con error de negocio (force salta el backoff).
    for (var i = 0; i < OfflinePosService.maxAttempts; i++) {
      final r = await sync(biz, force: true);
      expect(r.failed, 1, reason: 'intento ${i + 1} debe fallar');
    }
    expect(await svc.deadActionsCount(biz), 1);
    expect(await svc.pendingActionsCount(biz), 0);
    expect(inventory.calls, OfflinePosService.maxAttempts);

    // El visor ve la acción con su estado y el error real.
    final stuck = await svc.unsettledActions(biz);
    expect(stuck, hasLength(1));
    expect(stuck.single['status'], 'dead');
    expect(stuck.single['last_error'], contains('constraint'));

    // Causa raíz "corregida": el próximo replay funcionaría…
    inventory.succeed = true;

    // …pero el sync automático NO la toca (dead no reintenta sola).
    final auto = await sync(biz, force: false);
    expect(auto.processed, 0);
    expect(auto.dead, 1);
    expect(inventory.calls, OfflinePosService.maxAttempts);

    // El manual (botón "Sincronizar ahora") la reintenta y completa.
    final forced = await sync(biz, force: true);
    expect(forced.completed, 1);
    expect(forced.dead, 0);
    expect(await svc.deadActionsCount(biz), 0);
    expect(await svc.pendingActionsCount(biz), 0);
    expect(await svc.unsettledActions(biz), isEmpty);
  });
}
