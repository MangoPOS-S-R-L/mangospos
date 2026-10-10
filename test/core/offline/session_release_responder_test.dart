// T02 (20261010_0030): las liberaciones automáticas de mesa esperan la
// confirmación de cada terminal participante. Este equipo responde los pedidos
// con lo que tiene de esas órdenes sin subir; salir de una mesa vacía (también
// desde la cola) confirma con el equipo y su cola.

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/session_release_responder.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _busyOrder = '0e000000-0000-4000-8000-000000000001';
const _emptyOrder = '0e000000-0000-4000-8000-000000000002';

class _Sales extends SalesRepository {
  _Sales(super.client);

  var requests = <({String sessionId, int version, List<String> orderIds})>[];
  Object? requestsError;
  int requestCalls = 0;

  /// 'sesión@versión:pendientes' por confirmación.
  final acks = <String>[];

  /// 'orden|equipo|pendientes' por liberación al salir de la mesa.
  final releases = <String>[];

  @override
  Future<List<({String sessionId, int version, List<String> orderIds})>>
  pendingReleaseRequests(String businessId, String deviceId) async {
    requestCalls++;
    final error = requestsError;
    if (error != null) throw error;
    return requests;
  }

  @override
  Future<Map<String, dynamic>?> ackSessionRelease({
    required String sessionId,
    required String deviceId,
    required int version,
    required bool hasPendingWork,
  }) async {
    acks.add('$sessionId@$version:$hasPendingWork');
    return {'released': !hasPendingWork};
  }

  @override
  Future<bool> releaseEmptyTableIfNeeded(
    String orderId, {
    String? businessId,
    String? deviceId,
    bool hasPendingWork = true,
  }) async {
    releases.add('$orderId|$deviceId|$hasPendingWork');
    return !hasPendingWork;
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
    client = SupabaseClient('http://localhost:54321', 'test');
  });

  tearDownAll(() async {
    await db.close();
    await client.dispose();
  });

  setUp(() {
    service.setHubUploader(null);
    sales = _Sales(client);
  });

  Future<void> enqueueAdd(String biz, String orderId) => service.enqueueAction(
    businessId: biz,
    action: {
      'id': '$biz-add',
      'type': 'add_item',
      'order_id': orderId,
      'origin': 'table',
      'item_id': 'tmp_pollo',
      'menu_item_id': 'pollo',
      'qty': 1,
    },
  );

  test('confirma cada pedido con lo que tiene sin subir de esas órdenes', () async {
    const biz = 'release-responder-mixed';
    await enqueueAdd(biz, _busyOrder);
    sales.requests = [
      (sessionId: 'session-busy', version: 4, orderIds: [_busyOrder]),
      (sessionId: 'session-empty', version: 7, orderIds: [_emptyOrder]),
    ];
    final responder = SessionReleaseResponder(
      repository: () => sales,
      deviceId: () async => 'tablet-A',
    );
    expect(await responder.respond(biz), 2);
    expect(sales.acks, ['session-busy@4:true', 'session-empty@7:false']);
  });

  test('una orden local con productos en cola cuenta por su id del servidor', () async {
    const biz = 'release-responder-mapped';
    // La orden subió (mapeo local → remoto) pero un alta suya sigue en cola.
    await enqueueAdd(biz, 'local-order-mesa-3');
    await service.debugSaveOrderMapping(
      businessId: biz,
      localOrderId: 'local-order-mesa-3',
      remoteOrderId: _busyOrder,
    );
    // El servidor pregunta por su id; el alta en cola lleva el local.
    expect(await service.hasPendingWorkForOrders(biz, {_busyOrder}), isTrue);
    expect(await service.hasPendingWorkForOrders(biz, {_emptyOrder}), isFalse);
  });

  test('respeta su intervalo y, sin la migración, se pausa', () async {
    const biz = 'release-responder-throttle';
    var now = DateTime(2026, 10, 10, 12);
    final responder = SessionReleaseResponder(
      repository: () => sales,
      deviceId: () async => 'tablet-A',
      clock: () => now,
    );
    await responder.respond(biz);
    await responder.respond(biz);
    expect(sales.requestCalls, 1, reason: 'dentro de los 30 s no consulta');
    now = now.add(const Duration(seconds: 31));
    sales.requestsError = const PostgrestException(
      message: 'Could not find the function fn_pending_release_requests',
      code: 'PGRST202',
    );
    expect(await responder.respond(biz), 0);
    expect(sales.requestCalls, 2);
    now = now.add(const Duration(minutes: 5));
    await responder.respond(biz);
    expect(sales.requestCalls, 2, reason: 'sin la migración espera 10 min');
    now = now.add(const Duration(minutes: 6));
    sales.requestsError = null;
    await responder.respond(biz);
    expect(sales.requestCalls, 3);
  });

  test('la liberación encolada al salir de una mesa vacía confirma con el '
      'equipo y su cola', () async {
    const biz = 'release-replay';
    await service.enqueueAction(
      businessId: biz,
      action: {
        'id': '$biz-release-empty',
        'type': 'release_empty_order',
        'order_id': _emptyOrder,
      },
    );
    await service.enqueueAction(
      businessId: biz,
      action: {
        'id': '$biz-release-busy',
        'type': 'release_empty_order',
        'order_id': _busyOrder,
      },
    );
    await enqueueAdd(biz, _busyOrder);
    await service.syncPendingActions(
      businessId: biz,
      salesRepository: sales,
      printingService: PrintingService(client),
      inventoryRepository: InventoryRepository(client),
      cashierRepository: CashierRepository(client),
      force: true,
    );
    expect(sales.releases, hasLength(2));
    expect(sales.releases.first, startsWith('$_emptyOrder|'));
    expect(sales.releases.first, endsWith('|false'));
    expect(sales.releases.first.split('|')[1], isNotEmpty);
    expect(
      sales.releases.last,
      endsWith('|true'),
      reason: 'su alta sigue en la cola: no confirma vacía',
    );
  });
}
