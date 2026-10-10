import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// §11.1 (Hub híbrido / anti-pérdida): `listPendingTableDrafts` devuelve las
/// mesas con borrador LOCAL sin sincronizar (orden `local-order-…`) para que el
/// grid del salón las overlaye y NO desaparezcan al recargar desde el server.
/// - Solo origen 'table'.
/// - Solo mientras la orden siga siendo local (tras el remap a uuid real, ya
///   no es "pendiente").
/// - Aisladas por negocio.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock del canal de flutter_secure_storage (clave del SecureBlobCipher que
  // cifra los snapshots).
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
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
    // inyectamos una DB en memoria ANTES de que el service toque la cola.
    OfflineQueueDb.debugInstance = OfflineQueueDb.inMemory(
      NativeDatabase.memory(),
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final svc = OfflinePosService();

  // NOTA: OfflinePosService + StorageService son singletons y los snapshots se
  // acumulan durante la corrida; usamos un businessId único por test (todo
  // está namespaced por negocio) para aislar sin depender de un reset global.

  test('vacío cuando no hay borradores', () async {
    expect(await svc.listPendingTableDrafts('biz-empty'), isEmpty);
  });

  test(
    'badge cuenta estados con una sola consulta sin abrir payloads',
    () async {
      const biz = 'biz-status-counts';
      for (final status in ['pending', 'failed', 'dead', 'completed']) {
        await svc.enqueueAction(
          businessId: biz,
          action: {
            'id': 'status-$status',
            'type': 'inventory_adjust',
            'status': status,
          },
        );
      }
      expect(await svc.queueStatusCounts(biz), (pending: 2, dead: 1));
    },
  );

  test('devuelve la mesa con borrador local sin sincronizar', () async {
    await svc.createLocalDraft(
      businessId: 'biz-a',
      origin: 'table',
      tableId: 'table-A',
    );
    final drafts = await svc.listPendingTableDrafts('biz-a');
    expect(drafts.length, 1);
    expect(drafts.first.tableId, 'table-A');
  });

  test('excluye orígenes que no son mesa (venta rápida)', () async {
    await svc.createLocalDraft(businessId: 'biz-quick', origin: 'quick');
    expect(await svc.listPendingTableDrafts('biz-quick'), isEmpty);
  });

  test('los negocios no se mezclan', () async {
    await svc.createLocalDraft(
      businessId: 'biz-iso-1',
      origin: 'table',
      tableId: 'table-A',
    );
    expect(await svc.listPendingTableDrafts('biz-iso-2'), isEmpty);
    expect((await svc.listPendingTableDrafts('biz-iso-1')).length, 1);
  });

  test('excluye la mesa ya sincronizada (remap a uuid real)', () async {
    final draft = await svc.createLocalDraft(
      businessId: 'biz-remap',
      origin: 'table',
      tableId: 'table-A',
    );
    final localId = draft.order!.id;
    // Simula el sync: el id local pasa a un uuid real y local_only=false.
    await svc.remapSnapshotOrderId(
      businessId: 'biz-remap',
      localOrderId: localId,
      remoteOrderId: 'real-uuid-123',
    );
    expect(await svc.listPendingTableDrafts('biz-remap'), isEmpty);
  });

  test(
    'mesa remapeada con contenido pendiente sigue en overlay (sync parcial)',
    () async {
      const biz = 'biz-partial';
      final draft = await svc.createLocalDraft(
        businessId: biz,
        origin: 'table',
        tableId: 'table-A',
      );
      final localId = draft.order!.id;
      // add_item aún en cola con el id LOCAL (así quedan tras un sync parcial:
      // open_table replayó, los ítems no).
      await svc.enqueueAction(
        businessId: biz,
        action: {
          'type': 'add_item',
          'origin': 'table',
          'order_id': localId,
          'item_id': 'tmp_1',
          'qty': 1,
        },
      );
      // Simula el replay de open_table: mapping local→remoto + remap snapshot.
      final storage = await StorageService.getInstance();
      await storage.writeJson('offline_order_map_$biz', {
        localId: 'real-uuid-456',
      });
      await svc.remapSnapshotOrderId(
        businessId: biz,
        localOrderId: localId,
        remoteOrderId: 'real-uuid-456',
      );
      // Sin el criterio de contenido pendiente, la mesa desaparecería del
      // overlay con la sesión del server aún vacía.
      final drafts = await svc.listPendingTableDrafts(biz);
      expect(drafts.length, 1);
      expect(drafts.first.tableId, 'table-A');
    },
  );

  test('void_order pendiente libera la mesa del overlay', () async {
    const biz = 'biz-void';
    final draft = await svc.createLocalDraft(
      businessId: biz,
      origin: 'table',
      tableId: 'table-A',
    );
    final localId = draft.order!.id;
    await svc.enqueueAction(
      businessId: biz,
      action: {'type': 'void_order', 'origin': 'table', 'order_id': localId},
    );
    expect(await svc.listPendingTableDrafts(biz), isEmpty);
  });

  test('cobro total offline no revive el borrador de mesa', () async {
    const biz = 'biz-paid-draft';
    final draft = await svc.createLocalDraft(
      businessId: biz,
      origin: 'table',
      tableId: 'table-A',
    );
    final orderId = draft.order!.id;
    await svc.enqueueAction(
      businessId: biz,
      action: {
        'type': 'add_item',
        'order_id': orderId,
        'item_id': 'tmp_1',
        'qty': 1,
      },
    );
    await svc.enqueueAction(
      businessId: biz,
      action: {'type': 'process_payment', 'order_id': orderId, 'amount': 640},
    );
    expect(await svc.listPendingTableDrafts(biz), isEmpty);
  });

  test('abono parcial no libera una mesa con contenido pendiente', () async {
    const biz = 'biz-partial-payment-draft';
    final draft = await svc.createLocalDraft(
      businessId: biz,
      origin: 'table',
      tableId: 'table-A',
    );
    final orderId = draft.order!.id;
    await svc.enqueueAction(
      businessId: biz,
      action: {
        'type': 'add_item',
        'order_id': orderId,
        'item_id': 'tmp_1',
        'qty': 1,
      },
    );
    await svc.enqueueAction(
      businessId: biz,
      action: {
        'type': 'process_payment',
        'order_id': orderId,
        'check_id': 'check-1',
        'close_order': false,
        'close_check': true,
      },
    );
    expect(await svc.listPendingTableDrafts(biz), hasLength(1));
  });

  test('discardLocalOrder purga cola y snapshot de la orden local', () async {
    const biz = 'biz-discard';
    final draft = await svc.createLocalDraft(
      businessId: biz,
      origin: 'table',
      tableId: 'table-A',
    );
    final localId = draft.order!.id;
    await svc.enqueueAction(
      businessId: biz,
      action: {
        'type': 'open_table',
        'origin': 'table',
        'order_id': localId,
        'table_id': 'table-A',
      },
    );
    await svc.enqueueAction(
      businessId: biz,
      action: {
        'type': 'add_item',
        'origin': 'table',
        'order_id': localId,
        'item_id': 'tmp_1',
        'qty': 2,
      },
    );
    expect(await svc.pendingActionsCount(biz), 2);

    expect(
      await svc.discardLocalOrder(businessId: biz, localOrderId: localId),
      isTrue,
    );

    // Ni acciones pendientes (no se recrea la mesa al reconectar) ni
    // snapshot (el overlay suelta la mesa).
    expect(await svc.pendingActionsCount(biz), 0);
    expect(await svc.listPendingTableDrafts(biz), isEmpty);
    expect(await svc.loadSnapshot(businessId: biz, slotId: 'table-A'), isNull);
  });

  // Caso FOOD SHOP 2026-10-09 (#949B): venta rápida cobrada sin internet,
  // precuenta entregada, y "Descartar venta"/"Salir" la borró de la cola con
  // su cobro. Nunca llegó al servidor.
  test('discardLocalOrder NO borra una venta local ya cobrada', () async {
    const biz = 'biz-discard-paid';
    final draft = await svc.createLocalDraft(businessId: biz, origin: 'quick');
    final localId = draft.order!.id;
    await svc.enqueueAction(
      businessId: biz,
      action: {
        'type': 'add_item',
        'origin': 'quick',
        'order_id': localId,
        'item_id': 'tmp_1',
        'qty': 1,
      },
    );
    await svc.enqueueAction(
      businessId: biz,
      action: {
        'type': 'process_payment',
        'origin': 'offline',
        'order_id': localId,
        'amount': 309.66,
        'close_order': true,
      },
    );
    expect(
      await svc.hasQueuedPayment(businessId: biz, orderId: localId),
      isTrue,
    );

    expect(
      await svc.discardLocalOrder(businessId: biz, localOrderId: localId),
      isFalse,
    );

    // La venta entera sigue en la cola para subir: productos y cobro.
    final left = await svc.unsettledActions(biz);
    expect(left.map((a) => a['type']), ['add_item', 'process_payment']);
    expect(await svc.loadSnapshot(businessId: biz, slotId: 'quick'), isNotNull);
  });

  test('hasQueuedPayment solo cuenta cobros sin subir de esa orden', () async {
    const biz = 'biz-queued-payment';
    await svc.enqueueAction(
      businessId: biz,
      action: {
        'id': 'paid-already',
        'type': 'process_payment',
        'order_id': 'local-order-A',
        'amount': 100,
        'status': 'completed',
      },
    );
    await svc.enqueueAction(
      businessId: biz,
      action: {
        'type': 'add_item',
        'order_id': 'local-order-B',
        'item_id': 'tmp_2',
        'qty': 1,
      },
    );
    await svc.enqueueAction(
      businessId: biz,
      action: {
        'type': 'process_payment',
        'order_id': 'order-real-C',
        'amount': 50,
      },
    );

    // Ya subido, solo productos, y cobro pendiente de una orden del servidor.
    expect(
      await svc.hasQueuedPayment(businessId: biz, orderId: 'local-order-A'),
      isFalse,
    );
    expect(
      await svc.hasQueuedPayment(businessId: biz, orderId: 'local-order-B'),
      isFalse,
    );
    expect(
      await svc.hasQueuedPayment(businessId: biz, orderId: 'order-real-C'),
      isTrue,
    );
  });

  test(
    'intento al Hub impide tratar la orden como borrador descartable',
    () async {
      const biz = 'biz-hub-attempt';
      final draft = await svc.createLocalDraft(
        businessId: biz,
        origin: 'table',
        tableId: 'table-A',
      );
      final orderId = draft.order!.id;
      expect(
        await svc.mayExistRemotely(businessId: biz, orderId: orderId),
        isFalse,
      );
      await svc.enqueueAction(
        businessId: biz,
        action: {
          'type': 'open_table',
          'order_id': orderId,
          'table_id': 'table-A',
          'hub_delivery_started': true,
        },
      );
      expect(
        await svc.mayExistRemotely(businessId: biz, orderId: orderId),
        isTrue,
      );
    },
  );
}
