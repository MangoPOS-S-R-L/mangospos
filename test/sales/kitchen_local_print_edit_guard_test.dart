// Comanda LOCAL (impresión directa por la LAN): mientras imprime, las líneas
// de esa ronda no cambian de cantidad ni se borran. Antes, subirle la
// cantidad a una durante la impresión la dejaba «por confirmar» con la
// cantidad nueva y el siguiente «Enviar» la reimprimía entera (cocina recibía
// 2 + 3 para una orden de 3). Y un modal abierto antes del envío no puede,
// al guardar después, subir en sitio una línea que ya salió a cocina.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/business_settings_offline_cache.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
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
    activeBusinessName: 'Evento',
    userName: 'Cajero',
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

class _DelayedKitchen extends PrintingService {
  _DelayedKitchen(super.client, {this.fail = false});
  final bool fail;
  final started = Completer<void>();
  final release = Completer<void>();
  final printed = <List<OrderItem>>[];

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
    printed.add(localState.items);
    if (!started.isCompleted) started.complete();
    await release.future;
    if (fail) throw StateError('impresora caída');
    return const LocalKitchenSendResult(dispatchIds: {}, pendingAreas: []);
  }
}

/// Envío por la nube que se queda esperando la red y cae (sin imprimir nada):
/// confirmOrder repite la ronda por la LAN con lo que capturó al empezar.
class _CloudDropsToLan extends PrintingService {
  _CloudDropsToLan(super.client);
  final cloudStarted = Completer<void>();
  final dropNetwork = Completer<void>();
  final printed = <List<OrderItem>>[];

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
  }) async {
    if (!cloudStarted.isCompleted) cloudStarted.complete();
    await dropNetwork.future;
    throw KitchenSendNetworkException(TimeoutException('WAN unavailable'));
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
    printed.add(localState.items);
    return const LocalKitchenSendResult(dispatchIds: {}, pendingAreas: []);
  }
}

/// Alta en línea que espera a [release] y devuelve el id real «item-real»;
/// el servidor ya la trae en el bundle.
class _GatedAddRepository extends SalesRepository {
  _GatedAddRepository(super.client);
  final release = Completer<void>();
  final addStarted = Completer<void>();

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
    if (!addStarted.isCompleted) addStarted.complete();
    await release.future;
    return (itemId: 'item-real', replayed: false, itemExists: true);
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
      subtotal: 100,
      discounts: 0,
      serviceFee: 0,
      tax: 0,
      total: 100,
      createdAt: DateTime(2026, 10, 9),
    ),
    items: [
      OrderItem(
        id: 'item-real',
        orderId: orderId,
        productId: 'pollo',
        productName: 'Pollo',
        quantity: 1,
        unitPrice: 100,
        subtotal: 100,
        discounts: 0,
        tax: 0,
        total: 100,
        isTakeout: false,
        status: 'draft',
        createdAt: DateTime(2026, 10, 9),
      ),
    ],
    checks: const <OrderCheck>[],
    customerId: null,
    customerName: null,
    note: null,
  );
}

/// Servidor de una orden: las altas en línea (la primera retenida hasta
/// [releaseFirstAdd]) quedan en borrador; registra las confirmaciones a
/// cocina del replay.
class _ServerOrderRepository extends SalesRepository {
  _ServerOrderRepository(super.client, this.orderId);
  final String orderId;
  final releaseFirstAdd = Completer<void>();
  final firstAddStarted = Completer<void>();
  final serverItems = <OrderItem>[];
  final itemConfirms = <String>[];
  final wholeOrderConfirms = <String>[];

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
    final first = serverItems.isEmpty && !firstAddStarted.isCompleted;
    if (first) {
      firstAddStarted.complete();
      await releaseFirstAdd.future;
    }
    final id =
        '2b000000-0000-4000-8000-00000000000${serverItems.length + 1}';
    serverItems.add(
      OrderItem(
        id: id,
        orderId: orderId,
        productId: menuItemId,
        productName: menuItemId == 'pollo' ? 'Pollo' : 'Arroz',
        quantity: quantity,
        unitPrice: 100,
        subtotal: 100 * quantity,
        discounts: 0,
        tax: 0,
        total: 100 * quantity,
        isTakeout: false,
        status: 'draft',
        createdAt: DateTime(2026, 10, 10),
      ),
    );
    return (itemId: id, replayed: false, itemExists: true);
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

/// Impresión local que encola su 'confirm_local_order' como la real
/// (sendLocalOrderToKitchen): ids impresos por área y áreas que salieron.
class _EnqueuingKitchen extends PrintingService {
  _EnqueuingKitchen(super.client);
  final printed = <List<OrderItem>>[];

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
    final round = localState.items
        .where((item) => item.status == 'draft' || item.status == 'open')
        .toList(growable: false);
    printed.add(round);
    await OfflinePosService().enqueueAction(
      businessId: businessId,
      action: {
        'id': 'round-$businessId',
        'type': 'confirm_local_order',
        'order_id': localState.order!.id,
        'origin': localState.origin,
        'table_name': tableName,
        'item_ids_by_area': {
          'kitchen': [for (final item in round) item.id],
        },
        'printed_areas': ['kitchen'],
        'missing_areas': [],
      },
    );
    return const LocalKitchenSendResult(dispatchIds: {}, pendingAreas: []);
  }
}

class _CloudHub extends StateNotifier<TerminalMode>
    implements HubModeController {
  _CloudHub() : super(TerminalMode.cloud);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineQueueDb db;
  late SupabaseClient client;
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
      httpClient: MockClient(
        (request) async => throw TimeoutException('WAN unavailable'),
      ),
    );
  });

  setUp(() => ConnectivityService().simulateDisconnect());

  tearDownAll(() async {
    await db.close();
    await client.dispose();
  });

  Order order(String id) => Order(
    id: id,
    sessionId: 'session-$id',
    status: 'open',
    subtotal: 0,
    discounts: 0,
    serviceFee: 0,
    tax: 0,
    total: 0,
    createdAt: DateTime(2026, 10, 9),
  );

  Future<(ProviderContainer, _Sales)> prepare(
    String biz,
    PrintingService printing,
  ) async {
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await BusinessSettingsOfflineCache().saveRow(businessId: biz, row: {});
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(
          () => _Sales(CurrentOrderState(order: order('order-A'), origin: 'table')),
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        salesRepositoryProvider.overrideWithValue(SalesRepository(client)),
        printingServiceProvider.overrideWithValue(printing),
      ],
    );
    addTearDown(container.dispose);
    final vm = container.read(currentOrderProvider.notifier) as _Sales;
    await vm.addItem(
      menuItemId: 'pollo',
      productName: 'Pollo',
      productPrice: 100,
      qty: 2,
    );
    return (container, vm);
  }

  OrderItem line(ProviderContainer c, String productName) => c
      .read(currentOrderProvider)
      .items
      .firstWhere((i) => i.productName == productName);

  test('subir la cantidad durante la impresión se rechaza y la ronda queda '
      'enviada (sin reimpresión)', () async {
    const biz = 'kitchen-guard-qty';
    final printing = _DelayedKitchen(client);
    final (c, vm) = await prepare(biz, printing);
    final pollo = line(c, 'Pollo');
    expect(pollo.quantity, 2);

    final sending = vm.confirmOrder(tableName: 'Mesa 3');
    await printing.started.future;
    await vm.updateItemQuantity(pollo.id, 3);
    expect(line(c, 'Pollo').quantity, 2);
    expect(c.read(currentOrderProvider).error, contains('Espera'));

    printing.release.complete();
    await sending;

    final after = line(c, 'Pollo');
    expect(after.quantity, 2);
    expect(after.status, 'pending');
    expect(printing.printed.single.single.quantity, 2);
  });

  test('el modal durante la impresión avisa y no cambia la línea', () async {
    const biz = 'kitchen-guard-modal';
    final printing = _DelayedKitchen(client);
    final (c, vm) = await prepare(biz, printing);
    final pollo = line(c, 'Pollo');

    final sending = vm.confirmOrder(tableName: 'Mesa 3');
    await printing.started.future;
    await expectLater(
      vm.updateItem(pollo.id, pollo.copyWith(quantity: 3)),
      throwsA(predicate((e) => e.toString().contains('Espera'))),
    );
    printing.release.complete();
    await sending;

    expect(line(c, 'Pollo').quantity, 2);
    expect(line(c, 'Pollo').status, 'pending');
  });

  test('borrar una línea que se está imprimiendo se rechaza', () async {
    const biz = 'kitchen-guard-delete';
    final printing = _DelayedKitchen(client);
    final (c, vm) = await prepare(biz, printing);
    final pollo = line(c, 'Pollo');

    final sending = vm.confirmOrder(tableName: 'Mesa 3');
    await printing.started.future;
    expect(await vm.deleteItem(pollo.id), isFalse);
    expect(line(c, 'Pollo').id, pollo.id);
    printing.release.complete();
    await sending;

    expect(line(c, 'Pollo').status, 'pending');
  });

  test('una línea agregada durante la impresión sí se puede editar', () async {
    const biz = 'kitchen-guard-new-line';
    final printing = _DelayedKitchen(client);
    final (c, vm) = await prepare(biz, printing);

    final sending = vm.confirmOrder(tableName: 'Mesa 3');
    await printing.started.future;
    await vm.addItem(menuItemId: 'agua', productName: 'Agua', productPrice: 50);
    final agua = line(c, 'Agua');
    await vm.updateItemQuantity(agua.id, 3);
    expect(line(c, 'Agua').quantity, 3);
    printing.release.complete();
    await sending;

    expect(line(c, 'Pollo').status, 'pending');
    expect(line(c, 'Agua').status, 'draft');
    expect(line(c, 'Agua').quantity, 3);
  });

  test('modal abierto antes del envío y guardado después: no sube en sitio '
      'una línea que ya salió a cocina', () async {
    const biz = 'kitchen-guard-stale-modal';
    final printing = _DelayedKitchen(client);
    final (c, vm) = await prepare(biz, printing);
    // Lo que capturó el modal al abrirse: la línea «por enviar».
    final captured = line(c, 'Pollo');

    final sending = vm.confirmOrder(tableName: 'Mesa 3');
    await printing.started.future;
    printing.release.complete();
    await sending;
    expect(line(c, 'Pollo').status, 'pending');

    await expectLater(
      vm.updateItem(captured.id, captured.copyWith(quantity: 3)),
      throwsA(predicate((e) => e.toString().contains('ya salió a cocina'))),
    );
    expect(line(c, 'Pollo').quantity, 2);
    expect(line(c, 'Pollo').status, 'pending');
  });

  test('la red cae durante el envío por la nube: la ronda no cambia en la '
      'espera y sale entera por la LAN, sin reimpresión', () async {
    const biz = 'kitchen-guard-cloud-to-lan';
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await BusinessSettingsOfflineCache().saveRow(businessId: biz, row: {});
    final printing = _CloudDropsToLan(client);
    OrderItem serverLine(String id, String name, double qty) => OrderItem(
      id: id,
      orderId: 'order-B',
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
      createdAt: DateTime(2026, 10, 9),
    );
    // Orden y líneas ya en el servidor (ids remotos): «Enviar» va por la nube.
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(
          () => _Sales(
            CurrentOrderState(
              order: order('order-B'),
              items: [
                serverLine('item-pollo', 'Pollo', 2),
                serverLine('item-arroz', 'Arroz', 1),
              ],
              origin: 'table',
            ),
          ),
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        salesRepositoryProvider.overrideWithValue(SalesRepository(client)),
        printingServiceProvider.overrideWithValue(printing),
      ],
    );
    addTearDown(c.dispose);
    final vm = c.read(currentOrderProvider.notifier) as _Sales;
    ConnectivityService().simulateReconnect();

    final sending = vm.confirmOrder(tableName: 'Mesa 4');
    await printing.cloudStarted.future;
    // Esperando la red: cambiar o borrar una línea de la ronda se rechaza.
    await vm.updateItemQuantity('item-pollo', 3);
    expect(line(c, 'Pollo').quantity, 2);
    expect(c.read(currentOrderProvider).error, contains('enviarse'));
    expect(await vm.deleteItem('item-arroz'), isFalse);

    printing.dropNetwork.complete();
    await sending;

    final printed = printing.printed.single;
    expect(printed.map((i) => (i.productName, i.quantity)), [
      ('Pollo', 2),
      ('Arroz', 1),
    ]);
    expect(line(c, 'Pollo').quantity, 2);
    expect(line(c, 'Pollo').status, 'pending');
    expect(line(c, 'Arroz').status, 'pending');
    // Ya enviada, la línea vuelve a poder cambiarse (sin el aviso de espera).
    await vm.updateItemQuantity('item-arroz', 2);
    expect(line(c, 'Arroz').quantity, 2);
  });

  test('alta en línea que termina durante la impresión: la línea con su id '
      'real sigue bloqueada y queda enviada', () async {
    const biz = 'kitchen-guard-tmp-renamed';
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await BusinessSettingsOfflineCache().saveRow(businessId: biz, row: {});
    final printing = _DelayedKitchen(client);
    final repository = _GatedAddRepository(client);
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(
          () => _Sales(CurrentOrderState(order: order('order-C'), origin: 'table')),
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        salesRepositoryProvider.overrideWithValue(repository),
        printingServiceProvider.overrideWithValue(printing),
      ],
    );
    addTearDown(c.dispose);
    final vm = c.read(currentOrderProvider.notifier) as _Sales;
    ConnectivityService().simulateReconnect();

    // El alta queda en vuelo con su línea temporal: «Enviar» va por la LAN.
    final adding = vm.addItem(
      menuItemId: 'pollo',
      productName: 'Pollo',
      productPrice: 100,
    );
    await repository.addStarted.future;
    expect(line(c, 'Pollo').id, startsWith('tmp_'));
    final sending = vm.confirmOrder(tableName: 'Mesa 5');
    await printing.started.future;

    repository.release.complete();
    await adding;
    expect(line(c, 'Pollo').id, 'item-real');

    // Durante la impresión, la línea con su id real no cambia.
    await vm.updateItemQuantity('item-real', 3);
    expect(line(c, 'Pollo').quantity, 1);
    expect(c.read(currentOrderProvider).error, contains('Espera'));

    printing.release.complete();
    await sending;

    final after = line(c, 'Pollo');
    expect(after.quantity, 1);
    expect(after.status, 'pending');
  });

  test('alta en línea que termina DESPUÉS de imprimir la comanda local: guarda '
      'su mapeo y, al sincronizar, se confirma solo la ronda impresa; lo '
      'agregado después sigue en borrador', () async {
    const biz = 'kitchen-add-after-print';
    const orderId = '0c000000-0000-4000-8000-000000000001';
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await BusinessSettingsOfflineCache().saveRow(businessId: biz, row: {});
    final printing = _EnqueuingKitchen(client);
    final repository = _ServerOrderRepository(client, orderId);
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(
          () => _Sales(CurrentOrderState(order: order(orderId), origin: 'table')),
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        salesRepositoryProvider.overrideWithValue(repository),
        printingServiceProvider.overrideWithValue(printing),
      ],
    );
    addTearDown(c.dispose);
    final vm = c.read(currentOrderProvider.notifier) as _Sales;
    ConnectivityService().simulateReconnect();

    // El alta queda en vuelo con su línea temporal: «Enviar» va por la LAN y
    // la comanda termina de imprimirse antes que el alta.
    final adding = vm.addItem(
      menuItemId: 'pollo',
      productName: 'Pollo',
      productPrice: 100,
    );
    await repository.firstAddStarted.future;
    final tmpId = line(c, 'Pollo').id;
    expect(tmpId, startsWith('tmp_'));
    await vm.confirmOrder(tableName: 'Mesa 6');
    expect(printing.printed.single.single.id, tmpId);

    repository.releaseFirstAdd.complete();
    await adding;
    final realId = repository.serverItems.single.id;
    // El alta esperó a guardar el mapeo aunque la impresión ya terminó.
    expect(
      await OfflinePosService().mappedRemoteItemId(
        businessId: biz,
        localItemId: tmpId,
      ),
      realId,
    );

    // Producto nuevo después de la comanda: nunca salió a cocina.
    await vm.addItem(menuItemId: 'arroz', productName: 'Arroz', productPrice: 50);
    final arrozId = repository.serverItems.last.id;
    expect(line(c, 'Arroz').status, 'draft');

    await OfflinePosService().syncPendingActions(
      businessId: biz,
      salesRepository: repository,
      printingService: printing,
      inventoryRepository: InventoryRepository(client),
      cashierRepository: CashierRepository(client),
      force: true,
    );

    expect(repository.itemConfirms, ['$orderId:$realId']);
    expect(repository.itemConfirms.single, isNot(contains(arrozId)));
    expect(repository.wholeOrderConfirms, isEmpty);
    expect(await OfflinePosService().unsettledActions(biz), isEmpty);
    expect(line(c, 'Arroz').status, 'draft');
  });

  test('si la impresión falla, las líneas vuelven a poder editarse', () async {
    const biz = 'kitchen-guard-failed-print';
    final printing = _DelayedKitchen(client, fail: true);
    final (c, vm) = await prepare(biz, printing);
    final pollo = line(c, 'Pollo');

    final sending = vm.confirmOrder(tableName: 'Mesa 3');
    await printing.started.future;
    printing.release.complete();
    await expectLater(sending, throwsA(isA<StateError>()));

    await vm.updateItemQuantity(pollo.id, 3);
    expect(line(c, 'Pollo').quantity, 3);
    expect(line(c, 'Pollo').status, 'draft');
  });
}
