// Dinero en el replay de la cola (y del op-log del Hub, que comparte
// _replayAction):
// - Un void_order encolado nunca anula una venta que el servidor ya tiene
//   cobrada o cerrada: lee la orden y la omite (skip, no dead).
// - PGRST202 (la app salió antes que la migración): no manda la acción a
//   dead-letter ni corta la pasada; sube sola cuando llega la migración.
// - Mesa abierta sin red por un mesero que el servidor ya no acepta
//   (EMPLOYEE_NOT_IN_BUSINESS): se reabre sin él en vez de atascar la venta.

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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Sales extends SalesRepository {
  _Sales(super.client);

  /// Estado de las órdenes en el servidor (lo que devuelve getOrder).
  final serverOrders = <String, Order>{};
  Object? getOrderError;
  final readOrders = <String>[];
  final closed = <(String, String)>[];
  final auditNotes = <(String, String)>[];

  Object? offlineSaleError;
  int offlineSaleCalls = 0;
  final added = <String>[];
  Object? addItemError;

  /// Mesas: error del servidor según el mesero (null = abre).
  Object? Function(String? employeeId) openTableError = (_) => null;
  final openTableCalls = <String?>[];

  /// fn_void_order_if_unpaid (20261009_0007). null = el servidor todavía no
  /// tiene la migración (PGRST202) y el replay usa el camino anterior.
  String Function(String orderId)? voidIfUnpaid;
  Object? voidIfUnpaidError;
  final guardedVoids = <String>[];

  @override
  Future<String> voidOrderIfUnpaid(String orderId) async {
    final error = voidIfUnpaidError;
    if (error != null) throw error;
    final answer = voidIfUnpaid;
    if (answer == null) {
      throw const PostgrestException(
        message:
            'Could not find the function public.fn_void_order_if_unpaid'
            '(p_order_id) in the schema cache',
        code: 'PGRST202',
      );
    }
    guardedVoids.add(orderId);
    return answer(orderId);
  }

  @override
  Future<Order?> getOrder(String orderId, {String? businessId}) async {
    readOrders.add(orderId);
    final error = getOrderError;
    if (error != null) throw error;
    return serverOrders[orderId];
  }

  @override
  Future<void> closeOrder({
    required String orderId,
    required String status,
  }) async {
    closed.add((orderId, status));
  }

  @override
  Future<void> appendVoidAuditNote({
    required String orderId,
    required String reason,
    String? userName,
    DateTime? voidedAt,
    String? businessId,
  }) async {
    auditNotes.add((orderId, reason));
  }

  @override
  Future<Map<String, dynamic>> openOfflineSale({
    required String origin,
    required String slot,
    required String businessId,
  }) async {
    offlineSaleCalls++;
    final error = offlineSaleError;
    if (error != null) throw error;
    return {'order_id': 'remote-$slot'};
  }

  @override
  Future<Map<String, dynamic>> openRetailCart({
    required String slot,
    required String businessId,
    int peopleCount = 1,
  }) async => {'order_id': 'remote-$slot'};

  @override
  Future<Map<String, dynamic>> openTable({
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    openTableCalls.add(openedByEmployeeId);
    final error = openTableError(openedByEmployeeId);
    if (error != null) throw error;
    return {'order_id': 'remote-$tableId'};
  }

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
    final addError = addItemError;
    if (addError != null) throw addError;
    added.add(orderId);
    return (
      itemId: 'remote-item-${added.length}',
      replayed: false,
      itemExists: true,
    );
  }
}

Order _serverOrder(String id, {required String status, String? closedAt}) =>
    Order.fromMap({
      'id': id,
      'session_id': 'session-$id',
      'status_ext': status,
      'subtotal': 100,
      'total': 100,
      'created_at': '2026-10-09T12:00:00Z',
      'closed_at': closedAt,
    });

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

  Future<OfflineQueueSyncResult> sync(String biz, {bool force = true}) =>
      service.syncPendingActions(
        businessId: biz,
        salesRepository: sales,
        printingService: PrintingService(client),
        inventoryRepository: InventoryRepository(client),
        cashierRepository: CashierRepository(client),
        force: force,
      );

  // Servidor sin 20261009_0007 (el fake responde PGRST202 por defecto): el
  // replay lee la orden y después cierra, como antes.
  group('void_order encolado', () {
    for (final (label, order) in [
      ('cobrada', _serverOrder('order-paid', status: 'paid')),
      ('anulada', _serverOrder('order-paid', status: 'void')),
      (
        'cerrada',
        _serverOrder(
          'order-paid',
          status: 'open',
          closedAt: '2026-10-09T12:30:00Z',
        ),
      ),
    ]) {
      test('venta $label en el servidor: se omite, nunca se anula', () async {
        final biz = 'void-guard-$label';
        sales.serverOrders['order-paid'] = order;
        await service.enqueueAction(
          businessId: biz,
          action: {'type': 'void_order', 'order_id': 'order-paid'},
        );

        final result = await sync(biz, force: false);

        expect(sales.readOrders, ['order-paid']);
        expect(sales.closed, isEmpty, reason: 'la venta cobrada sigue cobrada');
        expect(result.completed, 1, reason: 'skip: no queda pendiente');
        expect(result.dead, 0);
        expect(result.conflicts.single.actionType, 'void_order');
        expect(await service.pendingActionsCount(biz), 0);
      });
    }

    test(
      'orden local subida y cobrada: resuelve el mapping y la omite',
      () async {
        const biz = 'void-guard-mapped';
        final storage = await StorageService.getInstance();
        await storage.writeJson('offline_order_map_$biz', {
          'local-order-sold': 'remote-sold',
        });
        sales.serverOrders['remote-sold'] = _serverOrder(
          'remote-sold',
          status: 'paid',
        );
        await service.enqueueAction(
          businessId: biz,
          action: {'type': 'void_order', 'order_id': 'local-order-sold'},
        );

        await sync(biz);

        expect(sales.readOrders, ['remote-sold']);
        expect(sales.closed, isEmpty);
        expect(await service.pendingActionsCount(biz), 0);
      },
    );

    test(
      'venta abierta en el servidor: se anula como siempre, con su nota',
      () async {
        const biz = 'void-guard-open';
        sales.serverOrders['order-open'] = _serverOrder(
          'order-open',
          status: 'open',
        );
        await service.enqueueAction(
          businessId: biz,
          action: {
            'type': 'void_order',
            'order_id': 'order-open',
            'reason': 'Cliente se fue',
            'void_by': 'Cajero',
            'voided_at': '2026-10-09T12:40:00Z',
          },
        );

        final result = await sync(biz, force: false);

        expect(sales.closed, [('order-open', 'void')]);
        expect(sales.auditNotes, [('order-open', 'Cliente se fue')]);
        expect(result.completed, 1);
        expect(result.conflicts, isEmpty);
      },
    );

    test(
      'orden que no aparece en el negocio: comportamiento de siempre',
      () async {
        const biz = 'void-guard-unknown';
        await service.enqueueAction(
          businessId: biz,
          action: {'type': 'void_order', 'order_id': 'order-unknown'},
        );

        await sync(biz);

        expect(sales.closed, [('order-unknown', 'void')]);
      },
    );

    test('sin poder leer la orden (red): no anula y la acción sigue en la '
        'cola sin ir a dead-letter', () async {
      const biz = 'void-guard-read-fails';
      sales.getOrderError = Exception(
        'Error al obtener orden: ClientException: Connection reset by peer',
      );
      await service.enqueueAction(
        businessId: biz,
        action: {'type': 'void_order', 'order_id': 'order-x'},
      );

      for (var i = 0; i < OfflinePosService.maxAttempts + 1; i++) {
        final result = await sync(biz);
        expect(result.failed, 1);
      }

      expect(sales.closed, isEmpty);
      expect(await service.deadActionsCount(biz), 0);
      expect(await service.pendingActionsCount(biz), 1);

      // Vuelve la red y el servidor dice que se cobró: se omite.
      sales.getOrderError = null;
      sales.serverOrders['order-x'] = _serverOrder('order-x', status: 'paid');
      await sync(biz);
      expect(sales.closed, isEmpty);
      expect(await service.pendingActionsCount(biz), 0);
    });
  });

  group('void_order con la anulación protegida (20261009_0007)', () {
    for (final result in ['has_payments', 'already_closed', 'not_found']) {
      test('el servidor responde $result: se omite y nunca se cierra aparte',
          () async {
        final biz = 'guarded-void-$result';
        sales.voidIfUnpaid = (_) => result;
        await service.enqueueAction(
          businessId: biz,
          action: {'type': 'void_order', 'order_id': 'order-g'},
        );

        final sync1 = await sync(biz, force: false);

        expect(sales.guardedVoids, ['order-g']);
        expect(sales.readOrders, isEmpty, reason: 'sin lectura previa');
        expect(sales.closed, isEmpty, reason: 'nunca el cierre sin guarda');
        expect(sync1.completed, 1);
        expect(sync1.dead, 0);
        expect(sync1.conflicts.single.actionType, 'void_order');
        expect(await service.pendingActionsCount(biz), 0);
      });
    }

    test('el servidor anula: no hay cierre aparte y queda la nota', () async {
      const biz = 'guarded-void-ok';
      sales.voidIfUnpaid = (_) => 'voided';
      await service.enqueueAction(
        businessId: biz,
        action: {
          'type': 'void_order',
          'order_id': 'order-open',
          'reason': 'Cliente se fue',
          'void_by': 'Cajero',
          'voided_at': '2026-10-09T12:40:00Z',
        },
      );

      final result = await sync(biz, force: false);

      expect(sales.guardedVoids, ['order-open']);
      expect(sales.closed, isEmpty);
      expect(sales.auditNotes, [('order-open', 'Cliente se fue')]);
      expect(result.completed, 1);
      expect(result.conflicts, isEmpty);
    });

    test('sin red: no recurre al cierre sin guarda y sigue en la cola',
        () async {
      const biz = 'guarded-void-offline';
      sales.voidIfUnpaidError = Exception(
        'ClientException: Connection reset by peer',
      );
      sales.serverOrders['order-n'] = _serverOrder('order-n', status: 'open');
      await service.enqueueAction(
        businessId: biz,
        action: {'type': 'void_order', 'order_id': 'order-n'},
      );

      final result = await sync(biz);

      expect(result.failed, 1);
      expect(sales.closed, isEmpty);
      expect(sales.readOrders, isEmpty);
      expect(await service.deadActionsCount(biz), 0);
      expect(await service.pendingActionsCount(biz), 1);
    });
  });

  group('PGRST202: la app salió antes que su migración', () {
    test('la venta manual sin red no va a dead-letter ni frena la pasada; '
        'sube sola cuando llega la migración', () async {
      const biz = 'pgrst202-manual';
      sales.offlineSaleError = const PostgrestException(
        message:
            'Could not find the function public.fn_open_offline_sale'
            '(p_business_id, p_origin, p_people_count, p_slot, p_user_id) '
            'in the schema cache',
        code: 'PGRST202',
      );
      await service.enqueueAction(
        businessId: biz,
        action: {
          'type': 'add_item',
          'origin': 'manual',
          'order_id': 'local-order-manual',
          'item_id': 'tmp_manual',
          'menu_item_id': 'product',
          'qty': 1,
        },
      );
      // Otra venta detrás: la pasada no se corta por la función faltante.
      await service.enqueueAction(
        businessId: biz,
        action: {
          'type': 'add_item',
          'origin': 'quick',
          'order_id': 'local-order-other',
          'item_id': 'tmp_other',
          'menu_item_id': 'product',
          'qty': 1,
        },
      );

      final first = await sync(biz);
      expect(first.failed, 1);
      expect(first.completed, 1, reason: 'la otra venta sí subió');
      expect(sales.added, ['remote-quick-other']);
      // Con backoff: la pasada automática no la reintenta enseguida.
      expect(await service.hasActionsReadyToSync(biz), isFalse);

      for (var i = 0; i < OfflinePosService.maxAttempts + 1; i++) {
        final result = await sync(biz);
        expect(result.failed, 1);
      }
      expect(await service.deadActionsCount(biz), 0);
      final stuck = await service.unsettledActions(biz);
      expect(stuck.single['status'], 'failed');
      expect(
        (stuck.single['attempts'] as num).toInt(),
        greaterThan(OfflinePosService.maxAttempts),
      );

      // Se aplica la migración: sube sin que nadie toque la cola.
      sales.offlineSaleError = null;
      final healed = await sync(biz);
      expect(healed.completed, 1);
      expect(sales.added.last, 'remote-manual-manual');
      expect(await service.pendingActionsCount(biz), 0);
    });

    test('el repositorio ya tradujo el PGRST202 («Falta aplicar la migración '
        '…»): tampoco va a dead-letter', () async {
      const biz = 'pgrst202-idempotent-add';
      sales.addItemError = StateError(
        'Falta aplicar la migración de alta idempotente de ítems.',
      );
      await service.enqueueAction(
        businessId: biz,
        action: {
          'type': 'add_item',
          'origin': 'quick',
          'order_id': 'local-order-idem',
          'item_id': 'tmp_idem',
          'menu_item_id': 'product',
          'qty': 1,
        },
      );
      for (var i = 0; i < OfflinePosService.maxAttempts + 1; i++) {
        final result = await sync(biz);
        expect(result.failed, 1);
      }
      expect(await service.deadActionsCount(biz), 0);

      sales.addItemError = null;
      final healed = await sync(biz);
      expect(healed.completed, 1);
      expect(await service.pendingActionsCount(biz), 0);
    });

    test('otros errores del servidor siguen yendo a dead-letter', () async {
      const biz = 'pgrst-other-error';
      sales.offlineSaleError = const PostgrestException(
        message: 'ORIGIN_NOT_ALLOWED',
        code: 'P0001',
      );
      await service.enqueueAction(
        businessId: biz,
        action: {
          'type': 'add_item',
          'origin': 'manual',
          'order_id': 'local-order-manual-2',
          'item_id': 'tmp_manual_2',
          'menu_item_id': 'product',
          'qty': 1,
        },
      );
      for (var i = 0; i < OfflinePosService.maxAttempts; i++) {
        await sync(biz);
      }
      expect(await service.deadActionsCount(biz), 1);
    });
  });

  group('mesa abierta sin red por un mesero que ya no está activo', () {
    test('se reabre sin el mesero y la venta sube; la anotación local de '
        'quién la abrió se conserva', () async {
      const biz = 'opener-rejected';
      sales.openTableError = (employeeId) => employeeId == null
          ? null
          : Exception(
              'Error al abrir mesa: PostgrestException(message: '
              'EMPLOYEE_NOT_IN_BUSINESS, code: P0001, details: null, '
              'hint: null)',
            );
      final draft = await service.createLocalDraft(
        businessId: biz,
        origin: 'table',
        tableId: 'table-1',
        opener: (employeeId: 'emp-baja', name: 'Claudia'),
      );
      final localId = draft.order!.id;
      await service.enqueueAction(
        businessId: biz,
        action: {
          'type': 'open_table',
          'origin': 'table',
          'order_id': localId,
          'table_id': 'table-1',
        },
      );
      await service.enqueueAction(
        businessId: biz,
        action: {
          'type': 'add_item',
          'origin': 'table',
          'order_id': localId,
          'table_id': 'table-1',
          'item_id': 'tmp_mesa',
          'menu_item_id': 'product',
          'qty': 1,
        },
      );

      final result = await sync(biz, force: false);

      expect(sales.openTableCalls, ['emp-baja', null]);
      expect(result.failed, 0);
      expect(result.completed, 2);
      expect(sales.added, ['remote-table-1']);
      expect(
        await service.mappedRemoteOrderId(
          businessId: biz,
          localOrderId: localId,
        ),
        'remote-table-1',
      );
      final opener = await service.localOrderOpener(
        businessId: biz,
        orderId: 'remote-table-1',
      );
      expect(opener?.name, 'Claudia');
    });

    test('otro rechazo del servidor no se reintenta sin el mesero', () async {
      const biz = 'opener-other-error';
      sales.openTableError = (_) =>
          Exception('Error al abrir mesa: TABLE_BUSINESS_NOT_FOUND');
      await service.enqueueAction(
        businessId: biz,
        action: {
          'type': 'open_table',
          'origin': 'table',
          'order_id': 'local-order-mesa-x',
          'table_id': 'table-x',
          'opened_by_employee_id': 'emp-x',
        },
      );

      final result = await sync(biz);

      expect(sales.openTableCalls, ['emp-x']);
      expect(result.failed, 1);
    });
  });
}
