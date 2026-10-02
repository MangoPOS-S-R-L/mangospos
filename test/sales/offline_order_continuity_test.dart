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
import 'package:mangopos/core/offline/pending_kitchen_prints.dart';
import 'package:mangopos/core/offline/offline_catalog_service.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
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
    permissions: {'ventas.orden.agregar_item', 'ventas.orden.enviar_cocina'},
  );
}

// Seed an already-open table, as in the reported outage. Exercise real action
// handlers without startup/realtime timers or external authentication.
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

class _Printers extends PrintingRepository {
  _Printers(super.client);
  final printed = <String>[];
  final failedIps = <String>{};

  @override
  Future<void> printRawDirectTcp({
    required String ip,
    int port = 9100,
    required List<int> data,
    Duration timeout = const Duration(seconds: 5),
    int attempts = 2,
  }) async {
    if (failedIps.contains(ip)) throw StateError('Impresora apagada');
    expect(data, isNotEmpty);
    printed.add(ip);
  }

  @override
  Future<void> printRawViaAgent({
    required String ip,
    int port = 9100,
    required List<int> data,
  }) async => throw StateError('Agente no disponible');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineQueueDb db;
  late SupabaseClient client;
  var cloudRequests = 0;
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
        cloudRequests++;
        throw TimeoutException('WAN unavailable');
      }),
    );
  });

  setUp(() {
    cloudRequests = 0;
    ConnectivityService().simulateDisconnect();
  });

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
    createdAt: DateTime(2026, 9, 19),
  );

  Future<void> cachePrinter(String biz, String area, String ip) async {
    final storage = await StorageService.getInstance();
    await storage.writeList('printing_cached_printers_${biz}_$area', [
      {
        'id': 'printer-$ip',
        'business_id': biz,
        'name': area,
        'type': 'network',
        'ip_address': ip,
        'port': 9100,
        'is_active': true,
        'paper_width': 80,
        'created_at': '2026-09-19T00:00:00Z',
      },
    ]);
  }

  Future<ProviderContainer> containerFor(
    String biz,
    CurrentOrderState initial,
    PrintingService printing,
  ) async {
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await BusinessSettingsOfflineCache().saveRow(businessId: biz, row: {});
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(() => _Sales(initial)),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        salesRepositoryProvider.overrideWithValue(SalesRepository(client)),
        printingServiceProvider.overrideWithValue(printing),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('cobro confirmado no revive snapshot anterior al caer la red', () async {
    const biz = 'paid-then-offline';
    const table = 'table-paid-then-offline';
    final offline = OfflinePosService();
    final oldState = CurrentOrderState(
      order: order('paid-order'),
      origin: 'table',
    );
    await offline.saveSnapshot(
      businessId: biz,
      slotId: table,
      origin: 'table',
      tableId: table,
      state: oldState,
    );
    final container = await containerFor(
      biz,
      oldState,
      PrintingService(client),
    );

    await container
        .read(currentOrderProvider.notifier)
        .markPaidOrderLocally('paid-order');
    expect(container.read(currentOrderProvider).order, isNull);
    expect(await offline.loadSnapshot(businessId: biz, slotId: table), isNull);

    // Una escritura retrasada del pago viejo no debe volver a ocupar la mesa.
    await offline.saveSnapshot(
      businessId: biz,
      slotId: table,
      origin: 'table',
      tableId: table,
      state: oldState,
    );
    expect(await offline.loadSnapshot(businessId: biz, slotId: table), isNull);

    // El cierre se asocia a la orden, no a la mesa: una sesión nueva sí vive.
    await offline.saveSnapshot(
      businessId: biz,
      slotId: table,
      origin: 'table',
      tableId: table,
      state: CurrentOrderState(order: order('new-order'), origin: 'table'),
    );
    expect(
      (await offline.loadSnapshot(businessId: biz, slotId: table))?.order?.id,
      'new-order',
    );
  });

  test(
    'mesa existente: agrega y envía a la impresora LAN sin tocar nube',
    () async {
      const biz = 'outage-table';
      final printers = _Printers(client);
      await cachePrinter(biz, 'kitchen_hot', '192.168.1.20');
      final container = await containerFor(
        biz,
        CurrentOrderState(order: order('remote-order'), origin: 'table'),
        PrintingService(client, printingRepository: printers),
      );
      final vm = container.read(currentOrderProvider.notifier);
      await vm.addItem(
        menuItemId: 'product',
        productName: 'Pizza',
        productPrice: 100,
      );
      expect(container.read(currentOrderProvider).items.single.quantity, 1);
      final result = await vm.confirmOrder(tableName: 'Mesa 1');
      expect(result?.directAreas, ['kitchen_hot']);
      expect(result?.pendingPrintAreas, isEmpty);
      expect(result?.allDirect, isTrue);
      expect(printers.printed, ['192.168.1.20']);
      expect(
        container.read(currentOrderProvider).items.single.status,
        'pending',
      );
      expect(cloudRequests, 0);
      final queued = await OfflinePosService().unsettledActions(biz);
      expect(queued.map((a) => a['type']), ['add_item', 'confirm_local_order']);
      expect(queued.last['printed_areas'], ['kitchen_hot']);
      // La cuenta permanece recuperable tras salir de la pantalla.
      final restored = await OfflinePosService().loadSnapshot(
        businessId: biz,
        slotId: 'session-remote-order',
      );
      expect(restored!.items.single.productName, 'Pizza');
      expect(restored.items.single.status, 'pending');
    },
  );

  test(
    'reconexión antes de sync: cocina usa los ítems locales pendientes',
    () async {
      const biz = 'outage-reconnected';
      final printers = _Printers(client);
      await cachePrinter(biz, 'kitchen_hot', '192.168.1.21');
      final container = await containerFor(
        biz,
        CurrentOrderState(order: order('remote-reconnected'), origin: 'table'),
        PrintingService(client, printingRepository: printers),
      );
      final vm = container.read(currentOrderProvider.notifier);
      await vm.addItem(
        menuItemId: 'product',
        productName: 'Pizza',
        productPrice: 100,
      );
      ConnectivityService().simulateReconnect();
      await vm.confirmOrder();
      expect(printers.printed, ['192.168.1.21']);
      expect(cloudRequests, 0);
      expect(
        container.read(currentOrderProvider).items.single.status,
        'pending',
      );
    },
  );

  test(
    'impresora caída: conserva la comanda y avisa que falta imprimir',
    () async {
      const biz = 'outage-printer';
      final printers = _Printers(client)..failedIps.add('192.168.1.22');
      await cachePrinter(biz, 'kitchen_hot', '192.168.1.22');
      final container = await containerFor(
        biz,
        CurrentOrderState(order: order('remote-printer'), origin: 'table'),
        PrintingService(client, printingRepository: printers),
      );
      final vm = container.read(currentOrderProvider.notifier);
      await vm.addItem(
        menuItemId: 'product',
        productName: 'Pizza',
        productPrice: 100,
      );
      final result = await vm.confirmOrder();
      expect(result?.pendingPrintAreas, ['kitchen_hot']);
      expect(result?.allDirect, isFalse);
      expect(cloudRequests, 0);
      expect(printers.printed, isEmpty);
      expect(
        container.read(currentOrderProvider).error,
        contains('Pendiente de imprimir'),
      );
      final queued = await OfflinePosService().unsettledActions(biz);
      expect(queued.last['missing_areas'], ['kitchen_hot']);
      expect(queued.last['printed_areas'], isEmpty);
      expect(queued.last['item_ids_by_area']['kitchen_hot'], [
        container.read(currentOrderProvider).items.single.id,
      ]);
      final pending = await PendingKitchenPrints.instance.list(biz);
      expect(pending, hasLength(1));
      expect(pending.single.roundId, queued.last['id']);
      expect(pending.single.areaCode, 'kitchen_hot');
      expect(pending.single.itemIds, [
        container.read(currentOrderProvider).items.single.id,
      ]);
      await expectLater(
        PrintingService(
          client,
          printingRepository: printers,
        ).retryPendingKitchenPrint(
          businessId: biz,
          pendingId: pending.single.id,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Sincroniza esta ronda'),
          ),
        ),
      );
    },
  );

  test('sin cache de impresora: guarda y avisa, sin consultar nube', () async {
    const biz = 'outage-no-printer-cache';
    final container = await containerFor(
      biz,
      CurrentOrderState(order: order('remote-no-cache'), origin: 'table'),
      PrintingService(client, printingRepository: _Printers(client)),
    );
    final vm = container.read(currentOrderProvider.notifier);
    await vm.addItem(
      menuItemId: 'product',
      productName: 'Pizza',
      productPrice: 100,
    );
    final result = await vm.confirmOrder();
    expect(result?.pendingPrintAreas, ['kitchen_hot']);
    expect(result?.allDirect, isFalse);
    expect(cloudRequests, 0);
    expect(
      container.read(currentOrderProvider).error,
      contains('Pendiente de imprimir'),
    );
    final queued = await OfflinePosService().unsettledActions(biz);
    expect(queued.last['missing_areas'], ['kitchen_hot']);
  });

  test('registro de impresión dañado no impide encolar la comanda', () async {
    const biz = 'outage-corrupt-print-ledger';
    final storage = await StorageService.getInstance();
    await storage.write('pending_kitchen_prints_$biz', 'not-json');
    final container = await containerFor(
      biz,
      CurrentOrderState(order: order('remote-corrupt-ledger'), origin: 'table'),
      PrintingService(client, printingRepository: _Printers(client)),
    );
    final vm = container.read(currentOrderProvider.notifier);
    await vm.addItem(
      menuItemId: 'product',
      productName: 'Pizza',
      productPrice: 100,
    );

    final result = await vm.confirmOrder();
    expect(result?.pendingPrintAreas, ['kitchen_hot']);
    final queued = await OfflinePosService().unsettledActions(biz);
    expect(queued.last['type'], 'confirm_local_order');
    expect(queued.last['item_ids_by_area']['kitchen_hot'], hasLength(1));
    expect(await storage.read('pending_kitchen_prints_$biz'), 'not-json');
  });

  test('escáner: agrega por ID usando el producto preparado offline', () async {
    const biz = 'outage-barcode';
    await OfflineCatalogService().saveSnapshot(
      businessId: biz,
      products: [
        {
          'id': 'scan-product',
          'name': 'Agua',
          'price': 75,
          'category_id': 'drinks',
        },
      ],
    );
    final container = await containerFor(
      biz,
      CurrentOrderState(order: order('remote-scan'), origin: 'table'),
      PrintingService(client, printingRepository: _Printers(client)),
    );
    await container
        .read(currentOrderProvider.notifier)
        .addItem(menuItemId: 'scan-product');
    final item = container.read(currentOrderProvider).items.single;
    expect(item.productName, 'Agua');
    expect(item.unitPrice, 75);
    expect(cloudRequests, 0);
    expect(
      (await OfflinePosService().unsettledActions(biz)).single['type'],
      'add_item',
    );
  });

  test(
    'ruteo N:M local conserva cocina y bar aunque una impresora falle',
    () async {
      const biz = 'outage-multiple-areas';
      await OfflineCatalogService().saveSnapshot(
        businessId: biz,
        products: [
          {
            'id': 'product',
            'name': 'Combo',
            'print_area_code': 'kitchen_hot',
            'menu_item_print_areas': [
              {
                'print_areas': {'code': 'kitchen_hot', 'is_active': true},
              },
              {
                'print_areas': {'code': 'bar', 'is_active': true},
              },
            ],
          },
        ],
      );
      final printers = _Printers(client)..failedIps.add('192.168.1.31');
      await cachePrinter(biz, 'kitchen_hot', '192.168.1.30');
      await cachePrinter(biz, 'bar', '192.168.1.31');
      final container = await containerFor(
        biz,
        CurrentOrderState(
          order: order('remote-multiple-areas'),
          origin: 'table',
        ),
        PrintingService(client, printingRepository: printers),
      );
      final vm = container.read(currentOrderProvider.notifier);
      await vm.addItem(
        menuItemId: 'product',
        productName: 'Combo',
        productPrice: 100,
      );
      final result = await vm.confirmOrder();
      expect(result?.directAreas, ['kitchen_hot']);
      expect(result?.pendingPrintAreas, ['bar']);
      expect(result?.allDirect, isFalse);
      expect(cloudRequests, 0);
      expect(printers.printed, ['192.168.1.30']);
      final queued = await OfflinePosService().unsettledActions(biz);
      expect(queued.last['printed_areas'], ['kitchen_hot']);
      expect(queued.last['missing_areas'], ['bar']);
      expect(
        (await PendingKitchenPrints.instance.list(
          biz,
        )).map((entry) => entry.areaCode),
        ['bar'],
      );
    },
  );

  test(
    'caída durante carga online de cocina produce un error recuperable',
    () async {
      ConnectivityService().simulateReconnect();
      final service = PrintingService(
        client,
        printingRepository: _Printers(client),
      );
      await expectLater(
        service.sendOrderToKitchen(
          orderId: 'remote-outage',
          businessId: 'biz-outage',
        ),
        throwsA(isA<KitchenSendNetworkException>()),
      );
      expect(cloudRequests, greaterThan(0));
    },
  );
}
