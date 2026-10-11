// Fase 4 de la guía de cierre (S16): al abrir una mesa se pinta primero la
// copia guardada y luego llega el servidor. Mientras tanto la cuenta está
// «verificando» (la Pre-Cuenta no imprime sobre esa copia); al llegar el
// servidor queda verificada, y si no responde a tiempo queda marcada como
// posiblemente vieja. También: qué comandas de la cuenta siguen sin terminar
// (la Pre-Cuenta lo avisa sin ofrecer otro envío de esas rondas).

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/business_settings_offline_cache.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/pending_kitchen_prints.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _orderId = '0b200000-0000-4000-8000-000000000001';
const _miller = '7b000000-0000-4000-8000-000000000001';
const _juice = '7b000000-0000-4000-8000-000000000002';

class _Session extends SessionController {
  _Session(this.businessId);
  final String businessId;
  @override
  SessionState build() => SessionState(
    activeBusinessId: businessId,
    activeBusinessName: 'Medio Tiempo',
    userName: 'Caja',
    permissions: {'ventas.orden.agregar_item'},
  );
}

class _CloudHub extends StateNotifier<TerminalMode>
    implements HubModeController {
  _CloudHub() : super(TerminalMode.cloud);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

OrderItem _item(String id, String name, {String status = 'draft'}) => OrderItem(
  id: id,
  orderId: _orderId,
  productId: name,
  productName: name,
  quantity: 1,
  unitPrice: 225,
  subtotal: 225,
  discounts: 0,
  tax: 0,
  total: 225,
  isTakeout: false,
  status: status,
  createdAt: DateTime(2026, 10, 10, 21),
);

class _Server extends SalesRepository {
  _Server(super.client);
  List<OrderItem> items = [_item(_miller, '4x3 Miller', status: 'pending')];
  Completer<void>? holdOpen;

  @override
  Future<OpenTableResult> openTableAndLoad({
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    final wait = holdOpen;
    if (wait != null) await wait.future;
    return (
      orderId: _orderId,
      bundle: (
        order: Order(
          id: _orderId,
          sessionId: 'session-$_orderId',
          status: 'open',
          subtotal: 0,
          discounts: 0,
          serviceFee: 0,
          tax: 0,
          total: 0,
          createdAt: DateTime(2026, 10, 10, 20, 3),
        ),
        items: List.of(items),
        checks: const <OrderCheck>[],
        customerId: null,
        customerName: null,
        note: null,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineQueueDb db;
  late SupabaseClient client;
  final secureStore = <String, String>{};
  final offline = OfflinePosService();
  final defaultTimeout = SalesViewModel.accountCheckTimeout;

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
            return null;
          },
        );
    db = OfflineQueueDb.inMemory(NativeDatabase.memory());
    OfflineQueueDb.debugInstance = db;
    client = SupabaseClient('http://localhost:54321', 'test-key');
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient(
        (request) async => http.Response(
          request.method == 'GET' ? '[]' : 'null',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        ),
      ),
    );
  });

  setUp(() {
    offline.setHubUploader(null);
    ConnectivityService().simulateReconnect();
  });

  tearDown(() => SalesViewModel.accountCheckTimeout = defaultTimeout);

  tearDownAll(() async {
    ConnectivityService().simulateDisconnect();
    await db.close();
    await client.dispose();
    await Supabase.instance.dispose();
  });

  Future<(ProviderContainer, SalesViewModel)> salon(
    String biz,
    _Server server,
  ) async {
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await BusinessSettingsOfflineCache().saveRow(businessId: biz, row: {});
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        salesRepositoryProvider.overrideWithValue(server),
      ],
    );
    addTearDown(c.dispose);
    return (c, c.read(currentOrderProvider.notifier));
  }

  test('S16: reabrir una mesa muestra la copia guardada como «verificando» '
      'hasta que responde el servidor, que trae lo nuevo', () async {
    const biz = 's16-verify';
    final server = _Server(client);
    final (c, vm) = await salon(biz, server);
    await vm.openTable('A26');
    expect(c.read(currentOrderProvider).accountCheck, AccountCheck.verified);

    // Otra caja agregó productos que esta no vio.
    server.items = [
      _item(_miller, '4x3 Miller', status: 'pending'),
      _item(_juice, 'Jugo fresa'),
    ];
    final gate = server.holdOpen = Completer<void>();
    final reopening = vm.openTable('A26');
    await Future<void>.delayed(Duration.zero);
    final painted = c.read(currentOrderProvider);
    expect(painted.accountCheck, AccountCheck.verifying);
    expect(painted.items.map((i) => i.id), [_miller], reason: 'copia vieja');

    gate.complete();
    await reopening;
    final fresh = c.read(currentOrderProvider);
    expect(fresh.accountCheck, AccountCheck.verified);
    expect(fresh.items.map((i) => i.id), containsAll([_miller, _juice]));
  });

  test('S16: si el servidor no responde a tiempo, la copia queda marcada como '
      'posiblemente vieja (la Pre-Cuenta vuelve a poder usarse)', () async {
    const biz = 's16-timeout';
    final server = _Server(client);
    final (c, vm) = await salon(biz, server);
    await vm.openTable('A27');
    SalesViewModel.accountCheckTimeout = const Duration(milliseconds: 20);
    final gate = server.holdOpen = Completer<void>();
    final reopening = vm.openTable('A27');
    await Future<void>.delayed(Duration.zero);
    expect(c.read(currentOrderProvider).accountCheck, AccountCheck.verifying);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
      c.read(currentOrderProvider).accountCheck,
      AccountCheck.refreshFailed,
    );
    // La respuesta tardía sí la deja verificada.
    gate.complete();
    await reopening;
    expect(c.read(currentOrderProvider).accountCheck, AccountCheck.verified);
  });

  test('comandas de la cuenta sin terminar: enviada por LAN sin subir, '
      'incierta y sin imprimir; las de otra cuenta no cuentan', () async {
    const biz = 'rounds-of-order';
    final server = _Server(client);
    final (_, vm) = await salon(biz, server);
    await vm.openTable('A28');
    await offline.enqueueAction(
      businessId: biz,
      action: {
        'id': 'pend-sync',
        'type': 'confirm_local_order',
        'order_id': _orderId,
        'item_ids_by_area': {
          'cervezas': [_miller],
        },
        'printed_areas': ['cervezas'],
        'missing_areas': <String>[],
        'status': 'failed',
        'next_retry_at': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
      },
    );
    await offline.enqueueAction(
      businessId: biz,
      action: {
        'id': 'uncertain',
        'type': 'confirm_local_order',
        'order_id': _orderId,
        'status': 'dead',
        'kitchen_uncertain': true,
        'uncertain_areas': ['bar'],
      },
    );
    await offline.enqueueAction(
      businessId: biz,
      action: {
        'id': 'other-order',
        'type': 'confirm_local_order',
        'order_id': 'otra-orden',
        'status': 'failed',
        'next_retry_at': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
      },
    );
    await PendingKitchenPrints.instance.record(
      businessId: biz,
      roundId: 'cloud-round',
      orderId: _orderId,
      tableName: 'A28',
      itemIdsByArea: {
        'cocina': [_juice],
      },
    );

    final rounds = await vm.kitchenRoundsOfCurrentOrder();
    expect(rounds.pendingSync, 1);
    expect(rounds.uncertainAreas, {'bar'});
    expect(rounds.unprintedAreas, {'cocina'});
  });
}
