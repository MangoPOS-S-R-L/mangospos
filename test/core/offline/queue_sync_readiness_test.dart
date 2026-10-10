import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/shell/offline_sales_uplink_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pasadas automáticas solo cuando hay algo LISTO:
/// - `hasActionsReadyToSync` usa las mismas reglas que el loop de replay
///   (backoff, dead-letter, entregas al Hub, órdenes detenidas detrás de un
///   fallo, conciliación por marcador). Si dice "no", una pasada sin force
///   no reenvía ni concilia nada; si dice "sí", la pasada hace algo.
/// - El drenaje del uplink no corre la pasada si nada está listo.
/// - Encolar no falla por un snapshot ilegible de otra venta (V4).
class _FakeInventoryRepo extends InventoryRepository {
  _FakeInventoryRepo(super.client);

  bool succeed = true;
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
    bool queueOnNetworkFailure = true,
  }) async {
    calls++;
    if (!succeed) {
      throw Exception('violates check constraint "qty_positive"');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};
  late OfflineQueueDb db;
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
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
    db = OfflineQueueDb.inMemory(NativeDatabase.memory());
    OfflineQueueDb.debugInstance = db;
  });

  final svc = OfflinePosService();
  late final _FakeInventoryRepo inventory;
  late final SalesRepository sales;
  late final PrintingService printing;
  late final CashierRepository cashier;
  setUpAll(() {
    final client = SupabaseClient('http://localhost:54321', 'test-anon-key');
    inventory = _FakeInventoryRepo(client);
    sales = SalesRepository(client);
    printing = PrintingService(client);
    cashier = CashierRepository(client);
  });

  setUp(() {
    svc.setHubUploader(null);
    inventory
      ..succeed = true
      ..calls = 0;
  });
  tearDown(() => svc.setHubUploader(null));
  tearDownAll(() => db.close());

  Future<OfflineQueueSyncResult> sync(String biz, {bool force = false}) =>
      svc.syncPendingActions(
        businessId: biz,
        salesRepository: sales,
        printingService: printing,
        inventoryRepository: inventory,
        cashierRepository: cashier,
        force: force,
      );

  /// Filas de la cola en SQLite (incluye completadas): una poda las baja.
  Future<int> rowCount(String biz) async => (await (db.select(
    db.queueActions,
  )..where((t) => t.businessId.equals(biz))).get()).length;

  String inHours(int hours) =>
      DateTime.now().add(Duration(hours: hours)).toIso8601String();

  /// Acción de inventario: su replay solo toca el repo falso. `order_id`
  /// opcional para modelar varias acciones de una misma venta.
  Future<void> enqueue(
    String biz, {
    String? id,
    String? orderId,
    String? status,
    int? attempts,
    String? nextRetryAt,
    bool hubDeliveryStarted = false,
    String? fingerprint,
  }) => svc.enqueueAction(
    businessId: biz,
    action: {
      'id': ?id,
      'type': 'inventory_adjust',
      'warehouse_id': 'w1',
      'item_id': 'i1',
      'counted_quantity': 5,
      'reason_code': 'correction',
      'order_id': ?orderId,
      'status': ?status,
      'attempts': ?attempts,
      'next_retry_at': ?nextRetryAt,
      if (hubDeliveryStarted) 'hub_delivery_started': true,
      'fingerprint': ?fingerprint,
    },
  );

  /// Paridad con el loop: lo que dice la revisión es lo que hace una pasada
  /// sin force (y la revisión no reclama, no escribe ni llama al repo).
  Future<void> expectParity(String biz, bool expected) async {
    final callsBefore = inventory.calls;
    expect(await svc.hasActionsReadyToSync(biz), expected);
    expect(inventory.calls, callsBefore, reason: 'la revisión no replaya');
    final pass = await sync(biz);
    expect(
      pass.processed > 0 || pass.reconciled > 0,
      expected,
      reason: 'la pasada debe coincidir con la revisión',
    );
  }

  test('cola vacía o solo completadas: nada listo', () async {
    const biz = 'ready-empty';
    expect(await svc.hasActionsReadyToSync(biz), isFalse);
    await enqueue(biz);
    await sync(biz);
    expect(await svc.pendingActionsCount(biz), 0);
    await expectParity(biz, false);
  });

  test('acción nueva: lista', () async {
    await enqueue('ready-fresh');
    await expectParity('ready-fresh', true);
    expect(await svc.pendingActionsCount('ready-fresh'), 0);
  });

  test('fallida en backoff no despierta; vencida sí', () async {
    const waiting = 'ready-backoff-waiting';
    await enqueue(
      waiting,
      status: 'failed',
      attempts: 1,
      nextRetryAt: inHours(1),
    );
    await expectParity(waiting, false);
    expect(await svc.pendingActionsCount(waiting), 1);

    const due = 'ready-backoff-due';
    await enqueue(due, status: 'failed', attempts: 1, nextRetryAt: inHours(-1));
    await expectParity(due, true);
  });

  test('solo dead-letter: nada listo (requiere al cajero)', () async {
    const biz = 'ready-dead-only';
    await enqueue(biz, status: 'dead', attempts: OfflinePosService.maxAttempts);
    expect(await svc.pendingActionsCount(biz), 0);
    await expectParity(biz, false);
    expect(await svc.deadActionsCount(biz), 1);
  });

  test(
    'entrega al Hub en modo nube bloquea su orden pero no las demás',
    () async {
      const biz = 'ready-hub-owned';
      await enqueue(biz, orderId: 'order-hub', hubDeliveryStarted: true);
      await expectParity(biz, false);
      // Detrás, otra acción de la MISMA venta: espera como el resto.
      await enqueue(biz, orderId: 'order-hub');
      await expectParity(biz, false);
      // Una venta independiente sí sube.
      await enqueue(biz, orderId: 'order-other');
      await expectParity(biz, true);
    },
  );

  test('acción detrás de un fallo de su misma orden no despierta', () async {
    const biz = 'ready-blocked-behind';
    await enqueue(
      biz,
      orderId: 'order-a',
      status: 'failed',
      attempts: 2,
      nextRetryAt: inHours(1),
    );
    await enqueue(biz, orderId: 'order-a');
    await expectParity(biz, false);
    expect(await svc.pendingActionsCount(biz), 2);
  });

  test(
    'ya subida (marcador) detrás de una orden bloqueada: se concilia',
    () async {
      const biz = 'ready-reconcile';
      // Sube de verdad y deja el marcador de idempotencia 'op:op-recon'.
      await enqueue(biz, id: 'op-recon');
      expect((await sync(biz)).completed, 1);
      // Una copia de esa op (mismo marcador) quedó detrás de una entrega al Hub
      // de su misma venta y en backoff: el loop la concilia igual.
      await enqueue(biz, orderId: 'order-r', hubDeliveryStarted: true);
      await enqueue(
        biz,
        id: 'op-recon-copia',
        fingerprint: 'op:op-recon',
        orderId: 'order-r',
        status: 'failed',
        attempts: 1,
        nextRetryAt: inHours(1),
      );
      final callsBefore = inventory.calls;
      expect(await svc.hasActionsReadyToSync(biz), isTrue);
      final pass = await sync(biz);
      expect(pass.reconciled, 1);
      expect(pass.processed, 0);
      expect(inventory.calls, callsBefore);
      // Queda solo la entrega al Hub: ya no hay nada listo.
      await expectParity(biz, false);
    },
  );

  test(
    'tras un fallo real, la pasada automática siguiente no reintenta',
    () async {
      const biz = 'ready-after-failure';
      await enqueue(biz);
      inventory.succeed = false;
      final first = await sync(biz);
      expect(first.failed, 1);
      // Backoff de 3 s: se revisa de inmediato.
      await expectParity(biz, false);
      // El manual (force) sí reintenta.
      inventory.succeed = true;
      expect((await sync(biz, force: true)).completed, 1);
    },
  );

  test('modo Hub: lo ya intentado contra la nube no despierta', () async {
    const biz = 'ready-hub-mode';
    await enqueue(biz, orderId: 'order-cloud', status: 'failed', attempts: 1);
    await enqueue(biz, status: 'dead', attempts: OfflinePosService.maxAttempts);
    // Uploader puesto DESPUÉS de sembrar: encolar con Hub lo reenviaría.
    final uploaded = <String?>[];
    svc.setHubUploader((b, op) async {
      uploaded.add(op['order_id']?.toString());
      return uploaded.length;
    });
    expect(await svc.hasActionsReadyToSync(biz), isFalse);
    svc.setHubUploader(null);
    await enqueue(biz, orderId: 'order-lan');
    svc.setHubUploader((b, op) async {
      uploaded.add(op['order_id']?.toString());
      return uploaded.length;
    });
    expect(await svc.hasActionsReadyToSync(biz), isTrue);
    final flushed = await svc.flushPendingToHub(biz);
    expect(uploaded, ['order-lan']);
    expect(flushed.completed, 1);
    // El badge rojo no se apaga tras una pasada en modo Hub.
    expect(flushed.dead, 1);
    expect(flushed.pending, 1);
    expect(await svc.hasActionsReadyToSync(biz), isFalse);
  });

  test('pasada sin nada completado no poda ni reescribe la cola', () async {
    const biz = 'ready-no-prune';
    // 21 completadas SIN poda: el drenaje al Hub no poda.
    for (var i = 0; i < 21; i++) {
      await enqueue(biz, orderId: 'order-done-$i');
    }
    svc.setHubUploader((b, op) async => 1);
    expect((await svc.flushPendingToHub(biz)).completed, 21);
    svc.setHubUploader(null);
    await enqueue(
      biz,
      orderId: 'order-w',
      status: 'failed',
      attempts: 1,
      nextRetryAt: inHours(1),
    );
    expect(await rowCount(biz), 22);

    final idle = await sync(biz);
    expect(idle.completed, 0);
    expect(idle.reconciled, 0);
    expect(await rowCount(biz), 22, reason: 'sin completar nada no poda');

    // Una pasada que sí completa algo poda a 20 completadas y conserva la
    // pendiente.
    await enqueue(biz, orderId: 'order-fresh');
    expect((await sync(biz)).completed, 1);
    expect(await rowCount(biz), 21);
    final pending = await svc.unsettledActions(biz);
    expect(pending.single['order_id'], 'order-w');
    expect(pending.single['status'], 'failed');
  });

  group('drenaje del uplink', () {
    test('no corre pasada con backoff ni con acciones bloqueadas', () async {
      const biz = 'drain-nothing-ready';
      await enqueue(
        biz,
        orderId: 'order-b',
        status: 'failed',
        attempts: 1,
        nextRetryAt: inHours(1),
      );
      await enqueue(biz, orderId: 'order-b');
      var syncs = 0;
      Future<void> drain() => drainReadyOfflineSales(
        activeBusinessId: () => biz,
        hasReady: svc.hasActionsReadyToSync,
        sync: () async => syncs++,
      );
      await drain();
      await drain();
      expect(syncs, 0);
      expect(await svc.pendingActionsCount(biz), 2);
      // Una venta independiente lista sí dispara la pasada.
      await enqueue(biz, orderId: 'order-c');
      await drain();
      expect(syncs, 1);
    });
  });

  test(
    'encolar no falla por un snapshot ilegible de otra venta (V4)',
    () async {
      const biz = 'enqueue-corrupt-snapshot';
      final storage = await StorageService.getInstance();
      // Ilegible y ANTES que el bueno en el orden de llaves.
      await storage.write('offline_snapshot_${biz}_roto', 'borrador');
      const localId = 'local-order-v4';
      await svc.saveSnapshot(
        businessId: biz,
        slotId: 'mesa-7',
        origin: 'table',
        tableId: 'table-7',
        state: CurrentOrderState(
          origin: 'table',
          order: Order.fromMap({
            'id': localId,
            'session_id': 'local-session-v4',
            'status_ext': 'draft',
            'subtotal': 0,
            'total': 0,
            'created_at': '2026-10-09T12:00:00Z',
          }),
        ),
        localOnly: true,
      );
      await svc.enqueueAction(
        businessId: biz,
        action: {
          'type': 'add_item',
          'order_id': localId,
          'item_id': 'tmp_v4',
          'menu_item_id': 'product',
          'qty': 1,
        },
      );
      final queued = (await svc.unsettledActions(biz)).single;
      expect(queued['order_id'], localId);
      expect(queued['origin'], 'table');
      expect(queued['table_id'], 'table-7');
      expect(queued['slot_id'], 'mesa-7');
    },
  );
}
