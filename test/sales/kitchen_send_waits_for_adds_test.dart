// Fase 2 de la guía de cierre: «Enviar Pedido» mientras un producto, una
// oferta o sus extras todavía se guardan. Antes, cualquier línea temporal
// (`tmp_`) mandaba la ronda por la LAN estando online: la comanda salía, pero
// su confirmación quedaba en la cola de ese equipo y las demás cajas veían
// los productos «por confirmar» (Medio Tiempo, mesa A26, 10-10). Ahora se
// esperan las altas de la ronda (con tope) y, si el servidor la tiene
// completa, sale por la nube con SOLO las líneas capturadas al tocar.

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
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _orderId = '0d000000-0000-4000-8000-000000000001';
const _arrozId = '3d000000-0000-4000-8000-0000000000aa';

class _Session extends SessionController {
  _Session(this.businessId);
  final String businessId;
  @override
  SessionState build() => SessionState(
    activeBusinessId: businessId,
    activeBusinessName: 'Medio Tiempo',
    userName: 'Arianis',
    permissions: {
      'ventas.orden.agregar_item',
      'ventas.orden.editar_item',
      'ventas.orden.enviar_cocina',
    },
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

OrderItem _serverItem(String id, String name, {double qty = 1}) => OrderItem(
  id: id,
  orderId: _orderId,
  productId: name.toLowerCase(),
  productName: name,
  quantity: qty,
  unitPrice: 100,
  subtotal: 100 * qty,
  discounts: 0,
  tax: 0,
  total: 100 * qty,
  isTakeout: false,
  status: 'draft',
  createdAt: DateTime(2026, 10, 10),
);

/// Servidor de la orden. Cada alta puede quedar retenida en su compuerta
/// ([gates] por producto, `deal` para la oferta, [modifiersGate] para los
/// extras). Las altas son idempotentes por client_op_id, como la RPC real.
class _Server extends SalesRepository {
  _Server(super.client);

  final serverItems = <OrderItem>[_serverItem(_arrozId, 'Arroz')];
  final gates = <String, Completer<void>>{};
  final started = <String, Completer<void>>{};
  final addCalls = <String>[];
  final idsByClientOp = <String, String>{};
  Completer<void>? modifiersGate;
  final modifiersStarted = Completer<void>();
  final savedModifiers = <String>[];

  /// El alta hace commit y la respuesta se pierde (una vez).
  bool loseNextResponse = false;

  /// Servidor viejo: la oferta se guarda pero no informa su id.
  bool dealWithoutId = false;
  final itemConfirms = <String>[];
  final wholeOrderConfirms = <String>[];

  Completer<void> gate(String key) => gates[key] = Completer<void>();
  Future<void> whenStarted(String key) =>
      (started[key] ??= Completer<void>()).future;

  String _commit(String clientOpId, String name, double qty) {
    final existing = idsByClientOp[clientOpId];
    if (existing != null) return existing;
    final id =
        '3d000000-0000-4000-8000-${(serverItems.length + 1).toString().padLeft(12, '0')}';
    idsByClientOp[clientOpId] = id;
    serverItems.add(_serverItem(id, name, qty: qty));
    return id;
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
    addCalls.add(clientOpId);
    final began = started[menuItemId] ??= Completer<void>();
    if (!began.isCompleted) began.complete();
    final wait = gates[menuItemId];
    if (wait != null) await wait.future;
    final replayed = idsByClientOp.containsKey(clientOpId);
    final id = _commit(clientOpId, menuItemId, quantity);
    if (loseNextResponse) {
      loseNextResponse = false;
      throw http.ClientException('Connection reset by peer');
    }
    return (itemId: id, replayed: replayed, itemExists: true);
  }

  @override
  Future<String?> addOfferDealItem({
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    required double discount,
    required String name,
    String? promotionId,
    int checkPosition = 1,
    String? clientOpId,
    String? createdByEmployeeId,
  }) async {
    final began = started['deal'] ??= Completer<void>();
    if (!began.isCompleted) began.complete();
    final wait = gates['deal'];
    if (wait != null) await wait.future;
    final id = _commit(clientOpId!, name, quantity);
    return dealWithoutId ? null : id;
  }

  @override
  Future<void> addOrderItemModifiers({
    required String itemId,
    required List<Map<String, dynamic>> modifiers,
  }) async {
    if (!modifiersStarted.isCompleted) modifiersStarted.complete();
    final wait = modifiersGate;
    if (wait != null) await wait.future;
    savedModifiers.add(itemId);
  }

  @override
  Future<void> setItemCreatedByEmployee({
    required String itemId,
    required String employeeId,
  }) async {}

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
      createdAt: DateTime(2026, 10, 10),
    ),
    items: List.of(serverItems),
    checks: const <OrderCheck>[],
    customerId: null,
    customerName: null,
    note: null,
  );

  @override
  Future<void> confirmItemsToKitchen(
    String orderId,
    List<String> itemIds,
  ) async {
    itemConfirms.add('$orderId:${itemIds.join(',')}');
  }

  @override
  Future<({bool merged, DateTime roundStamp})> sendToKitchen(
    String orderId, {
    bool allowMerge = true,
  }) async {
    wholeOrderConfirms.add(orderId);
    return (merged: false, roundStamp: DateTime(2026, 10, 10));
  }
}

/// Registra por dónde salió cada comanda. La local encola su
/// 'confirm_local_order' como la real (ids impresos y áreas que salieron).
class _Kitchen extends PrintingService {
  _Kitchen(super.client);
  final cloudRounds = <Set<String>?>[];
  final localRounds = <List<String>>[];

  @override
  Future<KitchenSendResult> sendOrderToKitchen({
    required String orderId,
    required String businessId,
    String? fallbackTableName,
    String? fallbackWaiterName,
    Set<String> excludeItemIds = const {},
    Set<String> excludeAreaCodes = const {},
    bool allowKitchenMerge = true,
    KitchenAreaPrinterChooser? choosePrinter,
    bool forceChoosePrinter = false,
    Set<String>? onlyItemIds,
    bool recordFailedAreas = true,
  }) async {
    cloudRounds.add(onlyItemIds == null ? null : Set.of(onlyItemIds));
    return const KitchenSendResult(
      dispatchIds: {},
      directAreas: ['cervezas'],
      escalatedAreas: [],
    );
  }

  @override
  Future<LocalKitchenSendResult> sendLocalOrderToKitchen({
    required String businessId,
    required CurrentOrderState localState,
    String tableName = 'LOCAL',
    String? waiterName,
    String? businessName,
    KitchenAreaPrinterChooser? choosePrinter,
    bool forceChoosePrinter = false,
  }) async {
    final round = [
      for (final item in localState.items)
        if (item.status == 'draft' || item.status == 'open') item.id,
    ];
    localRounds.add(round);
    await OfflinePosService().enqueueAction(
      businessId: businessId,
      action: {
        'id': 'round-$businessId-${localRounds.length}',
        'type': 'confirm_local_order',
        'order_id': localState.order!.id,
        'origin': localState.origin,
        'table_name': tableName,
        'item_ids_by_area': {'cervezas': round},
        'printed_areas': ['cervezas'],
        'missing_areas': <String>[],
      },
    );
    return const LocalKitchenSendResult(dispatchIds: {}, pendingAreas: []);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineQueueDb db;
  late SupabaseClient client;
  final secureStore = <String, String>{};
  final offline = OfflinePosService();
  final defaultBudget = SalesViewModel.kitchenSendAddWaitBudget;

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
    client = SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: MockClient(
        (request) async => throw TimeoutException('lectura sin respuesta'),
      ),
    );
    // La recarga de la orden se suscribe a Realtime.
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

  tearDown(() {
    SalesViewModel.kitchenSendAddWaitBudget = defaultBudget;
  });

  tearDownAll(() async {
    ConnectivityService().simulateDisconnect();
    await db.close();
    await client.dispose();
    await Supabase.instance.dispose();
  });

  /// Mesa con «Arroz» ya guardado (borrador) en pantalla y en el servidor.
  Future<(ProviderContainer, SalesViewModel)> table(
    String biz,
    _Server server,
    _Kitchen kitchen,
  ) async {
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await BusinessSettingsOfflineCache().saveRow(businessId: biz, row: {});
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(
          () => _Sales(
            CurrentOrderState(
              order: Order(
                id: _orderId,
                sessionId: 'session-$_orderId',
                status: 'open',
                subtotal: 100,
                discounts: 0,
                serviceFee: 0,
                tax: 0,
                total: 100,
                createdAt: DateTime(2026, 10, 10),
              ),
              origin: 'table',
              items: [_serverItem(_arrozId, 'Arroz')],
            ),
          ),
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        salesRepositoryProvider.overrideWithValue(server),
        printingServiceProvider.overrideWithValue(kitchen),
      ],
    );
    addTearDown(c.dispose);
    return (c, c.read(currentOrderProvider.notifier));
  }

  OrderItem line(ProviderContainer c, String name) => c
      .read(currentOrderProvider)
      .items
      .lastWhere((item) => item.productName == name);

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<OfflineQueueSyncResult> sync(String biz, _Server server) =>
      offline.syncPendingActions(
        businessId: biz,
        salesRepository: server,
        printingService: _Kitchen(client),
        inventoryRepository: InventoryRepository(client),
        cashierRepository: CashierRepository(client),
      );

  test('S08: «Enviar» con un producto guardándose espera y manda por la nube '
      'SOLO la ronda capturada, sin pasar por la LAN ni la cola', () async {
    const biz = 's08-product';
    final server = _Server(client);
    final kitchen = _Kitchen(client);
    final (c, vm) = await table(biz, server, kitchen);
    final pollo = server.gate('pollo');

    final adding = vm.addItem(
      menuItemId: 'pollo',
      productName: 'Pollo',
      productPrice: 100,
    );
    await server.whenStarted('pollo');
    expect(line(c, 'Pollo').id, startsWith('tmp_'));

    final sending = vm.confirmOrder(tableName: 'A26');
    await settle();
    expect(kitchen.cloudRounds, isEmpty, reason: 'espera el alta');
    expect(kitchen.localRounds, isEmpty, reason: 'ya no cae a la LAN');

    pollo.complete();
    await adding;
    await sending;
    final polloId = server.idsByClientOp.values.single;
    expect(kitchen.cloudRounds, [
      {_arrozId, polloId},
    ]);
    expect(kitchen.localRounds, isEmpty);
    expect(
      await offline.unsettledActions(biz),
      isEmpty,
      reason: 'ninguna confirmación quedó en la cola de este equipo',
    );
  });

  test('S08: oferta («4x3») guardándose: misma espera y la línea real sale '
      'en la ronda', () async {
    const biz = 's08-deal';
    final server = _Server(client);
    final kitchen = _Kitchen(client);
    final (_, vm) = await table(biz, server, kitchen);
    final deal = server.gate('deal');

    final adding = vm.addOfferDeal(
      menuItemId: 'miller',
      lineQty: 4,
      discount: 225,
      name: '4x3 Miller',
      originalPrice: 225,
      promotionId: '91a19638-da08-4b72-868c-8a51aa6721e7',
    );
    await server.whenStarted('deal');
    final sending = vm.confirmOrder(tableName: 'A26');
    await settle();
    expect(kitchen.cloudRounds, isEmpty);

    deal.complete();
    await adding;
    await sending;
    final dealId = server.idsByClientOp.values.single;
    expect(kitchen.cloudRounds, [
      {_arrozId, dealId},
    ]);
    expect(kitchen.localRounds, isEmpty);
    expect(await offline.unsettledActions(biz), isEmpty);
  });

  test('[P2] oferta que no informa su id: no se amplía la confirmación a la '
      'orden entera; aviso visible y nada sale', () async {
    const biz = 's08-deal-no-id';
    final server = _Server(client)..dealWithoutId = true;
    final kitchen = _Kitchen(client);
    final (_, vm) = await table(biz, server, kitchen);
    final deal = server.gate('deal');

    final adding = vm.addOfferDeal(
      menuItemId: 'miller',
      lineQty: 4,
      discount: 225,
      name: '4x3 Miller',
      originalPrice: 225,
    );
    await server.whenStarted('deal');
    final refused = expectLater(
      vm.confirmOrder(tableName: 'A26'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'mensaje',
          contains('No se envió nada'),
        ),
      ),
    );
    deal.complete();
    await adding;
    await refused;
    expect(kitchen.cloudRounds, isEmpty, reason: 'ni la orden entera');
    expect(kitchen.localRounds, isEmpty);
  });

  test('S08: con extras, la comanda no sale hasta que los extras están '
      'guardados', () async {
    const biz = 's08-modifiers';
    final server = _Server(client);
    final kitchen = _Kitchen(client);
    final (_, vm) = await table(biz, server, kitchen);
    final modifiers = server.modifiersGate = Completer<void>();

    final adding = vm.addItem(
      menuItemId: 'hamburguesa',
      productName: 'Hamburguesa',
      productPrice: 300,
      selectedModifiers: const [
        SelectedModifierInput(name: 'Queso', price: 25),
      ],
    );
    await server.modifiersStarted.future; // la línea ya existe; faltan extras
    final sending = vm.confirmOrder(tableName: 'A26');
    await settle();
    expect(kitchen.cloudRounds, isEmpty, reason: 'sin extras no hay comanda');

    modifiers.complete();
    await adding;
    await sending;
    final burgerId = server.idsByClientOp.values.single;
    expect(server.savedModifiers, [burgerId]);
    expect(kitchen.cloudRounds, [
      {_arrozId, burgerId},
    ]);
  });

  test('S11: lo agregado mientras se espera va en su propia ronda: no se '
      'imprime ni se confirma con la anterior', () async {
    const biz = 's11';
    final server = _Server(client);
    final kitchen = _Kitchen(client);
    final (c, vm) = await table(biz, server, kitchen);
    final pollo = server.gate('pollo');

    final addingPollo = vm.addItem(
      menuItemId: 'pollo',
      productName: 'Pollo',
      productPrice: 100,
    );
    await server.whenStarted('pollo');
    final sending = vm.confirmOrder(tableName: 'A26');
    await settle();

    // Llega otro producto durante la espera (y termina antes).
    await vm.addItem(menuItemId: 'yuca', productName: 'Yuca', productPrice: 80);
    final yucaId = server.serverItems.last.id;

    pollo.complete();
    await addingPollo;
    await sending;
    final polloId = server.serverItems
        .firstWhere((item) => item.productName == 'pollo')
        .id;
    expect(kitchen.cloudRounds, [
      {_arrozId, polloId},
    ]);
    expect(kitchen.cloudRounds.single, isNot(contains(yucaId)));
    expect(line(c, 'yuca').status, 'draft', reason: 'sigue por confirmar');
  });

  test('S09: el alta tarda más que la espera: sale por la LAN y, al guardarse '
      'el mapeo, la cola confirma esa ronda una sola vez sin duplicar el '
      'producto', () async {
    const biz = 's09-late';
    SalesViewModel.kitchenSendAddWaitBudget = const Duration(milliseconds: 30);
    final server = _Server(client);
    final kitchen = _Kitchen(client);
    final (c, vm) = await table(biz, server, kitchen);
    final pollo = server.gate('pollo');

    final adding = vm.addItem(
      menuItemId: 'pollo',
      productName: 'Pollo',
      productPrice: 100,
    );
    await server.whenStarted('pollo');
    final tmpId = line(c, 'Pollo').id;
    await vm.confirmOrder(tableName: 'A26');
    expect(kitchen.cloudRounds, isEmpty);
    expect(kitchen.localRounds.single, containsAll([_arrozId, tmpId]));

    pollo.complete();
    await adding;
    final polloId = server.idsByClientOp.values.single;
    expect(
      await offline.mappedRemoteItemId(businessId: biz, localItemId: tmpId),
      polloId,
    );

    await sync(biz, server);
    expect(server.itemConfirms, ['$_orderId:$_arrozId,$polloId']);
    expect(server.wholeOrderConfirms, isEmpty);
    expect(server.addCalls.length, 1, reason: 'una sola alta');
    expect(
      server.serverItems.where((i) => i.productName == 'pollo'),
      hasLength(1),
    );
    expect(await offline.unsettledActions(biz), isEmpty);
  });

  test('S09: el alta hace commit y se pierde la respuesta: queda en la cola '
      'con su client_op_id, la ronda va por la LAN y el replay concilia el '
      'mismo producto y una sola confirmación', () async {
    const biz = 's09-lost';
    final server = _Server(client)..loseNextResponse = true;
    final kitchen = _Kitchen(client);
    final (c, vm) = await table(biz, server, kitchen);
    final pollo = server.gate('pollo');

    final adding = vm.addItem(
      menuItemId: 'pollo',
      productName: 'Pollo',
      productPrice: 100,
    );
    await server.whenStarted('pollo');
    final tmpId = line(c, 'Pollo').id;
    final sending = vm.confirmOrder(tableName: 'A26');
    await settle();
    pollo.complete();
    await adding;
    await sending;
    expect(kitchen.cloudRounds, isEmpty, reason: 'el servidor no confirmó');
    expect(kitchen.localRounds.single, containsAll([_arrozId, tmpId]));

    await sync(biz, server);
    final polloIds = server.serverItems
        .where((item) => item.productName == 'pollo')
        .map((item) => item.id)
        .toList();
    expect(polloIds, hasLength(1), reason: 'sin inserción duplicada');
    expect(server.addCalls.toSet(), hasLength(1), reason: 'mismo client_op_id');
    expect(server.itemConfirms, ['$_orderId:$_arrozId,${polloIds.single}']);
    expect(server.wholeOrderConfirms, isEmpty);
    expect(await offline.unsettledActions(biz), isEmpty);
  });

  test(
    'sin red al tocar «Enviar»: no espera y va por la LAN como siempre',
    () async {
      const biz = 'offline-no-wait';
      final server = _Server(client);
      final kitchen = _Kitchen(client);
      final (_, vm) = await table(biz, server, kitchen);
      ConnectivityService().simulateDisconnect();
      final started = DateTime.now();
      await vm.confirmOrder(tableName: 'A26');
      expect(
        DateTime.now().difference(started),
        lessThan(SalesViewModel.kitchenSendAddWaitBudget),
      );
      expect(kitchen.cloudRounds, isEmpty);
      expect(kitchen.localRounds.single, [_arrozId]);
    },
  );
}
