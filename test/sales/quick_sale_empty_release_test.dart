// Regla del dueño (11-oct): una venta rápida sin productos se libera. Caso
// 007 BAR N SNACK: 50 ventas rápidas abiertas (46 vacías) llenaron los
// carriles y el servidor dejó de abrir otra («no hay carril libre»); la
// cajera solo veía «No hay una orden activa». El barrido de vacías solo lo
// disparaba el salón, que ese local casi no usa.

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
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/data/repositories/zones_repository.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
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
    activeBusinessName: '007 BAR N SNACK',
    userName: 'ADAMES',
    permissions: {'ventas.orden.agregar_item'},
  );
}

class _Sales extends SalesViewModel {
  @override
  CurrentOrderState build() => const CurrentOrderState();

  @override
  Future<bool> ensureCashSessionOpen() async => true;
}

class _CloudHub extends StateNotifier<TerminalMode>
    implements HubModeController {
  _CloudHub() : super(TerminalMode.cloud);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Servidor de ventas rápidas: carriles llenos hasta que se barre, aperturas
/// que se pueden retener, y registro de lo que se libera.
class _Server extends SalesRepository {
  _Server(super.client);
  bool lanesFull = false;
  final opened = <String>[];
  final released = <String>[];
  Completer<void>? holdNextOpen;
  final openStarted = Completer<void>();

  @override
  Future<Map<String, dynamic>> openManualOrQuick({
    required String origin,
    String? customerName,
    int peopleCount = 1,
    String? businessId,
  }) async {
    if (!openStarted.isCompleted) openStarted.complete();
    final hold = holdNextOpen;
    holdNextOpen = null;
    if (hold != null) await hold.future;
    if (lanesFull) {
      throw Exception(
        'Error al abrir venta quick: PostgrestException(message: '
        'fn_open_manual_or_quick: no hay carril libre; hay 50 ventas sin '
        'cobrar en "Ventas rapidas". Cobra o anula alguna para abrir otra.)',
      );
    }
    final id =
        '0c3d0000-0000-4000-8000-${opened.length.toString().padLeft(12, '0')}';
    opened.add(id);
    return {'order_id': id, 'session_id': 'session-$id'};
  }

  @override
  Future<
    ({
      Order? order,
      List<OrderItem> items,
      List<OrderCheck> checks,
      String? customerId,
      String? customerName,
      String? note,
    })
  >
  getOrderBundle(String orderId, {String? businessId}) async => (
    order: Order(
      id: orderId,
      sessionId: 'session-$orderId',
      status: 'open',
      subtotal: 0,
      discounts: 0,
      serviceFee: 0,
      tax: 0,
      total: 0,
      createdAt: DateTime(2026, 10, 11, 14),
    ),
    items: const <OrderItem>[],
    checks: const <OrderCheck>[],
    customerId: null,
    customerName: null,
    note: null,
  );

  @override
  Future<bool> releaseEmptyTableIfNeeded(
    String orderId, {
    String? businessId,
    String? deviceId,
    bool hasPendingWork = true,
  }) async {
    released.add(orderId);
    return true;
  }
}

/// Barrido de vacías: libera los carriles.
class _Zones extends ZonesRepository {
  _Zones(super.sb, this.server);
  final _Server server;
  final sweeps = <int>[];

  /// Barrido a partir del cual se liberan los carriles (1 = el primero).
  int freesFromSweep = 1;

  @override
  Future<void> releaseEmptyTables(
    String businessId, {
    int graceMinutes = 15,
  }) async {
    sweeps.add(graceMinutes);
    if (sweeps.length >= freesFromSweep) server.lanesFull = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineQueueDb db;
  late SupabaseClient client;
  final secureStore = <String, String>{};

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
    OfflinePosService().setHubUploader(null);
    ConnectivityService().simulateReconnect();
  });

  tearDownAll(() async {
    ConnectivityService().simulateDisconnect();
    await db.close();
    await client.dispose();
    await Supabase.instance.dispose();
  });

  Future<(ProviderContainer, SalesViewModel, _Server, _Zones)> bar(
    String biz,
  ) async {
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await BusinessSettingsOfflineCache().saveRow(businessId: biz, row: {});
    final server = _Server(client);
    final zones = _Zones(client, server);
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(_Sales.new),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        salesRepositoryProvider.overrideWithValue(server),
        zonesRepoProvider.overrideWithValue(zones),
      ],
    );
    addTearDown(c.dispose);
    return (c, c.read(currentOrderProvider.notifier), server, zones);
  }

  test('carriles llenos de ventas vacías: se liberan las vacías y la venta '
      'rápida abre al reintentar', () async {
    final (c, vm, server, zones) = await bar('quick-lanes-full');
    server.lanesFull = true;
    // El barrido de rutina (al abrir) todavía no alcanza: el rechazo del
    // servidor dispara otro y el reintento.
    zones.freesFromSweep = 2;

    await vm.openQuick(forceRestart: true);

    final state = c.read(currentOrderProvider);
    expect(
      state.order?.id,
      server.opened.single,
      reason: 'abrió al reintentar',
    );
    expect(zones.sweeps, contains(SalesViewModel.virtualSaleSweepGraceMinutes));
    expect(state.error, isNull);
  });

  test('al abrir Venta Rápida se barren las vacías del negocio (el salón '
      'casi no se abre en un bar)', () async {
    final (_, vm, _, zones) = await bar('quick-sweep-on-open');
    await vm.openQuick(forceRestart: true);
    expect(zones.sweeps, [SalesViewModel.virtualSaleSweepGraceMinutes]);

    // Con tope: abrir otra enseguida no vuelve a barrer.
    await vm.openQuick(forceRestart: true);
    expect(zones.sweeps, hasLength(1));
  });

  test('apertura reemplazada por otra: la venta vacía que el servidor ya '
      'creó se libera en vez de quedar ocupando un carril', () async {
    final (c, vm, server, _) = await bar('quick-abandoned');
    final hold = server.holdNextOpen = Completer<void>();

    final first = vm.openQuick(forceRestart: true);
    await server.openStarted.future;
    // Otra apertura toma la pantalla mientras la primera espera al servidor.
    final second = vm.openQuick(forceRestart: true);
    hold.complete();
    await first;
    await second;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(server.opened, hasLength(2));
    final shown = c.read(currentOrderProvider).order?.id;
    final abandoned = server.opened.firstWhere((id) => id != shown);
    expect(server.released, [abandoned]);
    expect(server.released, isNot(contains(shown)));
  });
}
