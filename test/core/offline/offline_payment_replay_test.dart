// T07 (20261010_0008): los cobros hechos sin red suben con su identidad, su
// caja y su fecha. Si el servidor no puede aplicarlos tal cual, quedan «por
// decidir» (no se reintentan solos ni se mueven de caja) hasta una decisión
// explícita.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_state_db.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/offline_payment_replay.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _order = '0f000000-0000-4000-8000-000000000001';
const _session = '0f000000-0000-4000-8000-0000000000c1';

typedef _Replay = ({
  String key,
  String orderId,
  String? session,
  DateTime? paidAt,
  String? originSessionRef,
});

class _Server extends SalesRepository {
  _Server(super.client);

  final replays = <_Replay>[];
  final resolutions = <({String key, String resolution, String? target})>[];
  final legacy = <String>[];
  final scripted = <FutureOr<OfflinePaymentReplayResult?> Function()>[];
  final added = <String>[];

  @override
  Future<OfflinePaymentReplayResult?> replayOfflinePayment({
    required String paymentKey,
    required String orderId,
    String? checkId,
    required String paymentMethodId,
    required double amount,
    String? reference,
    String? customerId,
    String? customerRnc,
    String? fiscalType,
    String? cashierSessionId,
    double changeAmount = 0,
    bool closeOrder = true,
    bool closeCheck = true,
    int splitSequence = 0,
    DateTime? paidAt,
    String? offlineNcf,
    String? deviceId,
    String? originSessionRef,
  }) async {
    replays.add((
      key: paymentKey,
      orderId: orderId,
      session: cashierSessionId,
      paidAt: paidAt,
      originSessionRef: originSessionRef,
    ));
    if (scripted.isNotEmpty) return scripted.removeAt(0)();
    return const OfflinePaymentReplayResult(status: 'applied', paymentId: 'p1');
  }

  @override
  Future<OfflinePaymentReplayResult> resolveOfflinePayment({
    required String paymentKey,
    required String resolution,
    String? targetSessionId,
    String? note,
  }) async {
    resolutions.add((
      key: paymentKey,
      resolution: resolution,
      target: targetSessionId,
    ));
    return const OfflinePaymentReplayResult(status: 'resolved', paymentId: 'p2');
  }

  @override
  Future<Payment> processPayment({
    required String orderId,
    String? checkId,
    required String paymentMethodId,
    required double amount,
    String? reference,
    String? customerId,
    String? customerRnc,
    String? fiscalType,
    String? cashierSessionId,
    double changeAmount = 0,
    bool closeOrder = true,
    bool closeCheck = true,
    int splitSequence = 0,
    DateTime? paidAt,
    String? offlineNcf,
  }) async {
    legacy.add(orderId);
    return Payment.fromMap({
      'id': 'legacy-payment',
      'order_id': orderId,
      'amount': amount,
      'status': 'completed',
    });
  }

  @override
  Future<String> addItemFromMenu({
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
  }) async {
    added.add(menuItemId);
    return 'remote-item-${added.length}';
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
    final id = await addItemFromMenu(orderId: orderId, menuItemId: menuItemId);
    return (itemId: id, replayed: false, itemExists: true);
  }
}

OfflinePaymentReplayResult _needs(String reason) => OfflinePaymentReplayResult(
  status: 'needs_resolution',
  reason: reason,
  detail: const {'cash_session_id': _session},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  late OfflineQueueDb db;
  late HubStateDb hubDb;
  late SupabaseClient client;
  late _Server server;
  final service = OfflinePosService();

  setUpAll(() async {
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
            if (call.method == 'readAll') return Map.of(secureStore);
            if (call.method == 'delete') secureStore.remove(args['key']);
            return null;
          },
        );
    db = OfflineQueueDb.inMemory(NativeDatabase.memory());
    OfflineQueueDb.debugInstance = db;
    hubDb = HubStateDb.inMemory(NativeDatabase.memory());
    HubStateDb.debugInstance = hubDb;
    client = SupabaseClient('http://localhost:54321', 'test');
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient(
        (request) async => http.Response(
          request.url.path.endsWith('/fn_hub_lease_acquire')
              ? '{"held": true, "device_id": "este-equipo"}'
              : '[]',
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
  });

  tearDownAll(() async {
    await db.close();
    await hubDb.close();
    await client.dispose();
    await Supabase.instance.dispose();
  });

  setUp(() => server = _Server(client));

  Future<OfflineQueueSyncResult> sync(String biz, {bool force = true}) =>
      service.syncPendingActions(
        businessId: biz,
        salesRepository: server,
        printingService: PrintingService(client),
        inventoryRepository: InventoryRepository(client),
        cashierRepository: CashierRepository(client),
        force: force,
      );

  Future<void> enqueuePayment(String biz, String id, {String? session}) =>
      service.enqueueAction(
        businessId: biz,
        action: {
          'id': id,
          'type': 'process_payment',
          'order_id': _order,
          'payment_method_id': 'cash',
          'amount': 100,
          'cashier_session_id': session ?? _session,
          'paid_at': '2026-10-09T23:50:00.000Z',
        },
      );

  test('respuesta perdida: el reintento manda la misma identidad, su caja y '
      'su fecha', () async {
    const biz = 't07-lost';
    await enqueuePayment(biz, 'pay-1');
    server.scripted.add(() => throw TimeoutException('respuesta perdida'));

    await sync(biz);
    expect(await service.unsettledActions(biz), hasLength(1));
    await sync(biz);

    expect(server.replays, hasLength(2));
    expect(server.replays[0].key, server.replays[1].key);
    expect(server.replays[0].key, OfflinePosService.offlinePaymentKey('pay-1'));
    expect(server.replays.map((r) => r.session), [_session, _session]);
    expect(
      server.replays.map((r) => r.paidAt?.toUtc()),
      everyElement(DateTime.utc(2026, 10, 9, 23, 50)),
    );
    expect(await service.unsettledActions(biz), isEmpty);
  });

  test('caja ya cerrada: queda «por decidir», no se reintenta sola, frena su '
      'cuenta y se resuelve con una decisión explícita', () async {
    const biz = 't07-closed';
    await enqueuePayment(biz, 'pay-closed');
    await service.enqueueAction(
      businessId: biz,
      action: {
        'id': 'add-after',
        'type': 'add_item',
        'order_id': _order,
        'item_id': 'tmp_after',
        'menu_item_id': 'product',
        'qty': 1,
      },
    );
    server.scripted.add(() => _needs('cash_session_closed'));

    await sync(biz);

    final held = (await service.unsettledActions(
      biz,
    )).firstWhere((a) => a['id'] == 'pay-closed');
    expect(held['status'], 'dead');
    expect(held['payment_resolution'], 'cash_session_closed');
    expect(held['last_error'], contains('La caja de este cobro ya se cerró'));
    expect(server.legacy, isEmpty, reason: 'nunca el camino viejo encima');
    expect(server.added, isEmpty, reason: 'lo que sigue de su cuenta espera');

    // Sin decisión, una pasada normal no lo vuelve a mandar.
    await sync(biz, force: false);
    expect(server.replays, hasLength(1));

    final result = await service.resolveOfflinePayment(
      businessId: biz,
      actionId: 'pay-closed',
      resolution: OfflinePaymentResolution.postToOpenSession,
      salesRepository: server,
      targetSessionId: 'open-session',
    );
    expect(result.settled, isTrue);
    expect(server.resolutions.single.key, OfflinePosService.offlinePaymentKey('pay-closed'));
    expect(server.resolutions.single.target, 'open-session');
    expect(
      (await service.unsettledActions(biz)).map((a) => a['id']),
      isNot(contains('pay-closed')),
    );
    await sync(biz);
    expect(server.added, ['product'], reason: 'resuelto el cobro, sigue su cuenta');
  });

  test('servidor sin la migración: sube por el camino de siempre', () async {
    const biz = 't07-legacy';
    await enqueuePayment(biz, 'pay-legacy');
    server.scripted.add(() => null);

    await sync(biz);

    expect(server.legacy, [_order]);
    expect(await service.unsettledActions(biz), isEmpty);
  });

  test('«Limpiar dead» nunca descarta un cobro', () async {
    const biz = 't07-clear-dead';
    await enqueuePayment(biz, 'pay-dead');
    server.scripted.add(() => _needs('order_already_paid'));
    await sync(biz);

    expect(await service.clearDeadActions(biz), 0);
    expect(
      (await service.unsettledActions(biz)).single['payment_resolution'],
      'order_already_paid',
    );
  });

  test('caja abierta sin red y adoptada al sincronizar: el recibo lo dice', () async {
    const biz = 't07-adopted';
    final cashier = _AdoptingCashier(client);
    await service.enqueueAction(
      businessId: biz,
      action: {
        'id': 'open-local',
        'type': 'open_cash_session',
        'local_session_id': 'local-cash-session-1',
        'cash_register_id': 'register',
        'user_id': 'user',
        'start_amount': 0,
      },
    );
    await enqueuePayment(biz, 'pay-adopted', session: 'local-cash-session-1');

    await service.syncPendingActions(
      businessId: biz,
      salesRepository: server,
      printingService: PrintingService(client),
      inventoryRepository: InventoryRepository(client),
      cashierRepository: cashier,
      force: true,
    );

    expect(server.replays.single.session, 'server-open-session');
    expect(
      server.replays.single.originSessionRef,
      'local-cash-session-1 (caja ya abierta adoptada)',
    );
  });

  test('cobro de una caja cliente por el Hub: cuarentena «por decidir»; '
      'resuelto, el Hub ya no lo sube', () async {
    const biz = 't07-hub';
    await HubConfigService().setDeviceRole(biz, HubDeviceRole.hub);
    Future<OfflineQueueSyncResult> uplink() => service.syncHubOpLog(
      businessId: biz,
      salesRepository: server,
      printingService: PrintingService(client),
      inventoryRepository: InventoryRepository(client),
      cashierRepository: CashierRepository(client),
    );
    await service.appendToLocalHubOpLog(biz, {
      'id': 'hub-pay-1',
      'type': 'process_payment',
      'order_id': _order,
      'payment_method_id': 'cash',
      'amount': 100,
      'cashier_session_id': _session,
      'paid_at': '2026-10-09T23:50:00.000Z',
    });
    server.scripted.add(() => _needs('cash_session_closed'));

    await uplink();

    final held = (await service.unsettledActions(biz)).single;
    expect(held['quarantined_from'], 'hub_oplog');
    expect(held['payment_resolution'], 'cash_session_closed');
    expect(await service.unsettledHubActions(biz), hasLength(1));
    await uplink();
    expect(server.replays, hasLength(1), reason: 'en cuarentena no se repite');

    await service.resolveOfflinePayment(
      businessId: biz,
      actionId: 'hub-pay-1',
      resolution: OfflinePaymentResolution.postToOpenSession,
      salesRepository: server,
      targetSessionId: 'open-session',
    );
    await uplink();
    expect(server.replays, hasLength(1));
    expect(await service.unsettledActions(biz), isEmpty);
    expect(await service.unsettledHubActions(biz), isEmpty);
  });
}

/// El servidor ya tenía una caja abierta: la apertura sin red se cuelga de
/// ella.
class _AdoptingCashier extends CashierRepository {
  _AdoptingCashier(super.client);

  @override
  Future<Map<String, dynamic>> openSession({
    required String cashRegisterId,
    required String userId,
    required double startAmount,
    required String deviceId,
    String? deviceName,
  }) async => throw const CashRegisterException(
    errorCode: 'BUSINESS_CASH_ALREADY_OPEN',
    message: 'Ya hay una caja abierta en este negocio.',
    existingSessionId: 'server-open-session',
    existingBusinessId: 't07-adopted',
  );
}
