import 'dart:async';
import 'dart:convert';

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
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Session extends SessionController {
  _Session(this.businessId);
  final String businessId;
  @override
  SessionState build() => SessionState(
    activeBusinessId: businessId,
    activeBusinessName: 'Bar',
    userName: 'Mesero',
    permissions: {'ventas.orden.agregar_item'},
  );
}

class _Sales extends SalesViewModel {
  _Sales(this.initial);
  final CurrentOrderState initial;
  @override
  CurrentOrderState build() => initial;
}

class _CloudHub extends StateNotifier<TerminalMode>
    implements HubModeController {
  _CloudHub() : super(TerminalMode.cloud);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// "Se agregó, salió la comanda y después apareció dos veces": el servidor
/// guarda el ítem pero la respuesta se pierde. La acción encolada debe llevar
/// el MISMO client_op_id que el intento online (20260929_0001), para que el
/// replay devuelva ese ítem en vez de crear otro.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineQueueDb db;
  late SupabaseClient client;
  final rpcBodies = <Map<String, dynamic>>[];
  final secureStore = <String, String>{};

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
    client = SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/fn_add_item_from_menu_idempotent')) {
          rpcBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          // El INSERT hizo commit en el servidor, pero la respuesta no llega.
          throw TimeoutException('ack perdido');
        }
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
  });

  tearDownAll(() async {
    ConnectivityService().simulateDisconnect();
    await db.close();
    await client.dispose();
  });

  setUp(() {
    rpcBodies.clear();
    SalesRepository.debugResetIdempotentAddProbe();
    // "Conectado pero malo": el detector aún dice que hay internet.
    ConnectivityService().simulateReconnect();
  });

  Future<ProviderContainer> containerFor(String biz) async {
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await BusinessSettingsOfflineCache().saveRow(businessId: biz, row: {});
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(
          () => _Sales(
            CurrentOrderState(
              order: Order(
                id: '11111111-1111-1111-1111-111111111111',
                sessionId: 'session-1',
                status: 'open',
                subtotal: 0,
                discounts: 0,
                serviceFee: 0,
                tax: 0,
                total: 0,
                createdAt: DateTime(2026, 9, 29),
              ),
              origin: 'table',
            ),
          ),
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        salesRepositoryProvider.overrideWithValue(SalesRepository(client)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('respuesta perdida: se encola con el mismo client_op_id', () async {
    const biz = 'lost-ack';
    final container = await containerFor(biz);
    final vm = container.read(currentOrderProvider.notifier);

    await vm.addItem(
      menuItemId: 'menu-mojito',
      productName: 'Mojito Chinola',
      productPrice: 350,
    );

    expect(rpcBodies, hasLength(1), reason: 'un solo intento online');
    final sentOpId = rpcBodies.single['p_client_op_id'] as String;
    expect(sentOpId, isNotEmpty);

    final queued = await OfflinePosService().unsettledActions(biz);
    expect(queued.map((a) => a['type']), ['add_item']);
    expect(queued.single['client_op_id'], sentOpId);
    // El ítem sigue en pantalla mientras se sincroniza.
    expect(
      container.read(currentOrderProvider).items.single.productName,
      'Mojito Chinola',
    );
  });

  test('dos toques del mismo producto = dos client_op_id distintos', () async {
    const biz = 'two-taps';
    final container = await containerFor(biz);
    final vm = container.read(currentOrderProvider.notifier);

    await vm.addItem(
      menuItemId: 'menu-1',
      productName: 'Presidente',
      productPrice: 250,
    );
    // Fuera de la ventana anti doble-click (300 ms): es un segundo pedido real.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await vm.addItem(
      menuItemId: 'menu-1',
      productName: 'Presidente',
      productPrice: 250,
    );

    final ids = (await OfflinePosService().unsettledActions(
      biz,
    )).map((a) => a['client_op_id']).toList();
    expect(ids, hasLength(2));
    expect(ids.toSet(), hasLength(2));
  });
}
