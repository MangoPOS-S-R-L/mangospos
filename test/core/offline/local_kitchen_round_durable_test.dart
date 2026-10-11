// Fase 3 de la guía de cierre: la comanda local queda registrada en la cola
// ANTES del primer papel, reclamada por el proceso que imprime, y cada área
// anota su resultado. Si la app muere a mitad, el replay sabe qué salió (solo
// confirma), qué falta (lo imprime) y qué quedó INCIERTO (no lo reimprime ni
// lo confirma: queda visible para que alguien revise en el área).

import 'package:drift/drift.dart'
    show ApplyInterceptor, BatchedStatements, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/pending_kitchen_prints.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _order = '0f000000-0000-4000-8000-000000000001';
const _beer = '5f000000-0000-4000-8000-000000000001';
const _juice = '5f000000-0000-4000-8000-000000000002';

/// Hace fallar las escrituras de la cola a pedido.
class _WriteFailures extends QueryInterceptor {
  bool fail = false;

  void _check() {
    if (fail) throw StateError('disco lleno');
  }

  @override
  Future<int> runInsert(QueryExecutor e, String s, List<Object?> a) {
    _check();
    return super.runInsert(e, s, a);
  }

  @override
  Future<int> runUpdate(QueryExecutor e, String s, List<Object?> a) {
    _check();
    return super.runUpdate(e, s, a);
  }

  @override
  Future<int> runDelete(QueryExecutor e, String s, List<Object?> a) {
    _check();
    return super.runDelete(e, s, a);
  }

  @override
  Future<void> runBatched(QueryExecutor e, BatchedStatements s) {
    _check();
    return super.runBatched(e, s);
  }
}

class _Sales extends SalesRepository {
  _Sales(super.client);
  Object? confirmError;
  final itemConfirms = <String>[];
  final wholeOrderConfirms = <String>[];

  @override
  Future<void> confirmItemsToKitchen(
    String orderId,
    List<String> itemIds,
  ) async {
    final error = confirmError;
    if (error != null) throw error;
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

/// Lo que el replay pide imprimir por la nube.
class _CloudPrints extends PrintingService {
  _CloudPrints(super.client);
  final calls = <({Set<String>? only, Set<String> excluded})>[];

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
    calls.add((only: onlyItemIds, excluded: excludeAreaCodes));
    return const KitchenSendResult(
      dispatchIds: {},
      directAreas: ['bar'],
      escalatedAreas: [],
    );
  }
}

/// Impresoras de red falsas por IP: imprimen, fallan o quedan inciertas.
class _Thermals extends PrintingRepository {
  _Thermals(super.client);
  final behavior = <String, Object? Function()>{};
  final printedOn = <String>[];
  Future<void> Function(String ip)? beforePaper;

  @override
  Future<String> resolveReachableNetworkIp({
    required PrinterConfig printer,
    required String cachedIp,
    bool includeMacRecovery = true,
  }) async => cachedIp;

  @override
  Future<void> printRawDirectTcp({
    required String ip,
    int port = 9100,
    required List<int> data,
    Duration timeout = const Duration(seconds: 5),
    int attempts = 2,
  }) async {
    await beforePaper?.call(ip);
    final outcome = behavior[ip]?.call();
    if (outcome is Exception) throw outcome;
    printedOn.add(ip);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  final writes = _WriteFailures();
  late OfflineQueueDb db;
  late SupabaseClient client;
  late _Sales sales;
  late _CloudPrints cloud;
  final svc = OfflinePosService();
  final defaultTtl = OfflinePosService.localPrintClaimTtl;

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
    db = OfflineQueueDb.inMemory(NativeDatabase.memory().interceptWith(writes));
    OfflineQueueDb.debugInstance = db;
    client = SupabaseClient('http://localhost:54321', 'test-key');
  });

  tearDownAll(() async {
    await db.close();
    await client.dispose();
  });

  setUp(() {
    svc.setHubUploader(null);
    writes.fail = false;
    sales = _Sales(client);
    cloud = _CloudPrints(client);
  });

  tearDown(() => OfflinePosService.localPrintClaimTtl = defaultTtl);

  Future<OfflineQueueSyncResult> sync(String biz, {bool force = false}) =>
      svc.syncPendingActions(
        businessId: biz,
        salesRepository: sales,
        printingService: cloud,
        inventoryRepository: InventoryRepository(client),
        cashierRepository: CashierRepository(client),
        force: force,
      );

  Future<Map<String, dynamic>?> round(String biz, String id) async {
    for (final action in await svc.unsettledActions(biz)) {
      if (action['id'] == id) return action;
    }
    return null;
  }

  /// Reclamo de cada comanda abierta con [begin], por id de ronda.
  final claims = <String, String>{};

  Future<String> begin(String biz, String id) async =>
      claims[id] = await svc.beginLocalKitchenRound(
        businessId: biz,
        roundId: id,
        orderId: _order,
        origin: 'table',
        tableName: 'A26',
        itemIdsByArea: {
          'cervezas': [_beer],
          'bar': [_juice],
        },
        itemQuantities: {_beer: 4, _juice: 1},
      );

  /// Comanda que dejó OTRO arranque de la app (la que murió imprimiendo).
  Future<void> leftByCrashedProcess(
    String biz,
    String id,
    Map<String, String> areaResults,
  ) => svc.enqueueAction(
    businessId: biz,
    action: {
      'id': id,
      'type': 'confirm_local_order',
      'order_id': _order,
      'origin': 'table',
      'table_name': 'A26',
      'item_ids_by_area': {
        'cervezas': [_beer],
        'bar': [_juice],
      },
      'printed_areas': <String>[],
      'missing_areas': ['cervezas', 'bar'],
      'area_results': areaResults,
      'local_print_claim': {
        'process_id': 'arranque-anterior',
        'claimed_at': DateTime.now().toIso8601String(),
        'expires_at': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
      },
    },
  );

  group('reclamo de la impresión local', () {
    test('mientras imprime, el replay no la toca (ni con force); al terminar '
        'se confirma sola, sin reimprimir', () async {
      const biz = 'claim-live';
      await begin(biz, 'r1');
      expect(await svc.hasActionsReadyToSync(biz), isFalse);
      await sync(biz, force: true);
      expect(sales.itemConfirms, isEmpty);
      expect(cloud.calls, isEmpty);

      await svc.recordLocalKitchenArea(
        businessId: biz,
        roundId: 'r1',
        claimId: claims['r1']!,
        areaCode: 'cervezas',
        result: OfflinePosService.kitchenAreaDelivered,
      );
      await svc.recordLocalKitchenArea(
        businessId: biz,
        roundId: 'r1',
        claimId: claims['r1']!,
        areaCode: 'bar',
        result: OfflinePosService.kitchenAreaQueued,
      );
      await svc.finishLocalKitchenRound(
        businessId: biz,
        roundId: 'r1',
        claimId: claims['r1']!,
      );
      expect(await svc.hasActionsReadyToSync(biz), isTrue);

      await sync(biz);
      expect(sales.itemConfirms, ['$_order:$_beer,$_juice']);
      expect(cloud.calls, isEmpty, reason: 'S12: nada se reimprime');
      expect(await round(biz, 'r1'), isNull);
    });

    test('S12: un área sin impresora se imprime al volver la red; la '
        'entregada solo se confirma', () async {
      const biz = 'claim-partial';
      await begin(biz, 'r2');
      await svc.recordLocalKitchenArea(
        businessId: biz,
        roundId: 'r2',
        claimId: claims['r2']!,
        areaCode: 'cervezas',
        result: OfflinePosService.kitchenAreaDelivered,
      );
      await svc.recordLocalKitchenArea(
        businessId: biz,
        roundId: 'r2',
        claimId: claims['r2']!,
        areaCode: 'bar',
        result: OfflinePosService.kitchenAreaPending,
      );
      await svc.finishLocalKitchenRound(
        businessId: biz,
        roundId: 'r2',
        claimId: claims['r2']!,
      );
      await sync(biz);
      expect(cloud.calls.single.excluded, {'cervezas'});
      expect(cloud.calls.single.only, {_beer, _juice});
      expect(await round(biz, 'r2'), isNull);
    });

    test('reclamo vencido (la impresión se colgó): el replay la recupera con '
        'lo anotado', () async {
      const biz = 'claim-expired';
      OfflinePosService.localPrintClaimTtl = Duration.zero;
      await begin(biz, 'r3');
      await svc.recordLocalKitchenArea(
        businessId: biz,
        roundId: 'r3',
        claimId: claims['r3']!,
        areaCode: 'cervezas',
        result: OfflinePosService.kitchenAreaDelivered,
      );
      await svc.recordLocalKitchenArea(
        businessId: biz,
        roundId: 'r3',
        claimId: claims['r3']!,
        areaCode: 'bar',
        result: OfflinePosService.kitchenAreaDelivered,
      );
      expect(await svc.hasActionsReadyToSync(biz), isTrue);
      await sync(biz);
      expect(sales.itemConfirms, ['$_order:$_beer,$_juice']);
      expect(cloud.calls, isEmpty);
    });
  });

  group('S13: la app murió a mitad de la comanda', () {
    test('antes de imprimir nada: se imprime entera al sincronizar', () async {
      const biz = 's13-before';
      await leftByCrashedProcess(biz, 'c1', {});
      expect(await svc.hasActionsReadyToSync(biz), isTrue);
      await sync(biz);
      expect(cloud.calls.single.excluded, isEmpty);
      expect(cloud.calls.single.only, {_beer, _juice});
    });

    test('después de imprimir y antes del ACK: solo se confirma, sin '
        'reimprimir', () async {
      const biz = 's13-after';
      await leftByCrashedProcess(biz, 'c2', {
        'cervezas': OfflinePosService.kitchenAreaDelivered,
        'bar': OfflinePosService.kitchenAreaDelivered,
      });
      await sync(biz);
      expect(sales.itemConfirms, ['$_order:$_beer,$_juice']);
      expect(cloud.calls, isEmpty);
    });

    test(
      'durante el papel de un área: esa queda INCIERTA, sin reimprimir ni '
      'confirmar; lo demás se confirma y la incierta queda visible',
      () async {
        const biz = 's13-during';
        await leftByCrashedProcess(biz, 'c3', {
          'cervezas': OfflinePosService.kitchenAreaDelivered,
          'bar': OfflinePosService.kitchenAreaPrinting,
        });
        await sync(biz);
        expect(sales.itemConfirms, ['$_order:$_beer'], reason: 'solo cervezas');
        expect(cloud.calls, isEmpty, reason: 'nada se reimprime a ciegas');

        final held = await round(biz, 'c3');
        expect(held?['status'], 'dead');
        expect(held?['kitchen_uncertain'], isTrue);
        expect(held?['uncertain_areas'], ['bar']);
        expect(held?['item_ids_by_area'], {
          'bar': [_juice],
        }, reason: 'lo confirmado salió de la acción');
        expect(held?['last_error'], contains('Revisa en el área'));
        final visible = await PendingKitchenPrints.instance.list(biz);
        expect(visible.single.areaCode, 'bar');
        expect(visible.single.uncertain, isTrue);

        // Una pasada más (aunque sea forzada) no la reimprime ni la confirma.
        await sync(biz, force: true);
        expect(sales.itemConfirms, ['$_order:$_beer']);
        expect(cloud.calls, isEmpty);
      },
    );

    test('resolver «sí salió»: se confirma sin imprimir', () async {
      const biz = 's13-resolve-printed';
      await leftByCrashedProcess(biz, 'c4', {
        'cervezas': OfflinePosService.kitchenAreaDelivered,
        'bar': OfflinePosService.kitchenAreaPrinting,
      });
      await sync(biz);
      expect(
        await svc.resolveUncertainKitchenRound(
          businessId: biz,
          roundId: 'c4',
          printed: true,
        ),
        isTrue,
      );
      expect(await svc.hasActionsReadyToSync(biz), isTrue);
      await sync(biz);
      expect(sales.itemConfirms, ['$_order:$_beer', '$_order:$_juice']);
      expect(cloud.calls, isEmpty);
      expect(await round(biz, 'c4'), isNull);
      expect(await PendingKitchenPrints.instance.list(biz), isEmpty);
    });

    test(
      'resolver «no salió»: se imprime solo esa área y se confirma',
      () async {
        const biz = 's13-resolve-reprint';
        await leftByCrashedProcess(biz, 'c5', {
          'cervezas': OfflinePosService.kitchenAreaDelivered,
          'bar': OfflinePosService.kitchenAreaUncertain,
        });
        await sync(biz);
        await svc.resolveUncertainKitchenRound(
          businessId: biz,
          roundId: 'c5',
          printed: false,
        );
        await sync(biz);
        expect(cloud.calls.single.only, {_juice});
        expect(cloud.calls.single.excluded, isEmpty);
        expect(await round(biz, 'c5'), isNull);
      },
    );
  });

  test('S19: sin permiso en el servidor, la comanda se conserva con su motivo, '
      'no se completa y no se reimprime', () async {
    const biz = 's19-permission';
    await begin(biz, 'p1');
    for (final area in ['cervezas', 'bar']) {
      await svc.recordLocalKitchenArea(
        businessId: biz,
        roundId: 'p1',
        claimId: claims['p1']!,
        areaCode: area,
        result: OfflinePosService.kitchenAreaDelivered,
      );
    }
    await svc.finishLocalKitchenRound(
      businessId: biz,
      roundId: 'p1',
      claimId: claims['p1']!,
    );
    sales.confirmError = const PostgrestException(
      message:
          'permission denied for function fn_confirm_order_items_to_kitchen',
      code: '42501',
    );
    await sync(biz);
    final kept = await round(biz, 'p1');
    expect(kept?['status'], 'failed');
    expect(kept?['last_error'], isNotEmpty);
    expect(cloud.calls, isEmpty);
    expect(sales.itemConfirms, isEmpty);
  });

  group('impresión local real (impresoras de red falsas)', () {
    const cervezasIp = '10.0.0.11';
    const barIp = '10.0.0.12';

    Future<void> cachePrinter(
      String biz,
      String area,
      String ip, {
      String? secondIp,
    }) async {
      final storage = await StorageService.getInstance();
      await storage.writeList('printing_cached_printers_${biz}_$area', [
        for (final (index, address) in [ip, ?secondIp].indexed)
          PrinterConfig(
            id: 'printer-$area-$index',
            businessId: biz,
            name: 'Térmica $area $index',
            type: 'network',
            ipAddress: address,
            port: 9100,
            isActive: true,
            createdAt: DateTime(2026, 10, 10),
          ).toMap(),
      ]);
    }

    CurrentOrderState localRound() => CurrentOrderState(
      origin: 'table',
      order: Order(
        id: _order,
        sessionId: 'session-$_order',
        status: 'open',
        subtotal: 0,
        discounts: 0,
        serviceFee: 0,
        tax: 0,
        total: 0,
        createdAt: DateTime(2026, 10, 10),
      ),
      items: [
        for (final (id, name, area) in [
          (_beer, '4x3 Miller', 'cervezas'),
          (_juice, 'Jugo fresa', 'bar'),
        ])
          OrderItem(
            id: id,
            orderId: _order,
            productId: name,
            productName: name,
            quantity: 1,
            unitPrice: 100,
            subtotal: 100,
            discounts: 0,
            tax: 0,
            total: 100,
            isTakeout: false,
            status: 'draft',
            printAreaCode: area,
            createdAt: DateTime(2026, 10, 10),
          ),
      ],
    );

    test(
      'la ronda está en la cola, reclamada, ANTES del primer papel; cada '
      'área anota su resultado y la incierta no se da por entregada',
      () async {
        const biz = 'real-local';
        await cachePrinter(biz, 'cervezas', cervezasIp);
        await cachePrinter(biz, 'bar', barIp);
        final thermals = _Thermals(client);
        final seenBeforePaper = <String, Map<String, dynamic>?>{};
        thermals.beforePaper = (ip) async {
          final queued = await svc.unsettledActions(biz);
          seenBeforePaper[ip] = queued.isEmpty ? null : queued.single;
        };
        thermals.behavior[barIp] = () => const PrintDeliveryUncertainException(
          'el agente no respondió tras enviar los bytes',
        );
        final printing = PrintingService(
          client,
          printingRepository: thermals,
          salesRepository: sales,
        );

        final result = await printing.sendLocalOrderToKitchen(
          businessId: biz,
          localState: localRound(),
          tableName: 'A26',
        );

        final atFirstPaper = seenBeforePaper.values.first;
        expect(atFirstPaper, isNotNull, reason: 'registrada antes del papel');
        expect(
          OfflinePosService.isLocalKitchenRoundClaimed(atFirstPaper!),
          isTrue,
        );
        expect(
          (atFirstPaper['area_results'] as Map).values,
          contains(OfflinePosService.kitchenAreaPrinting),
        );

        expect(thermals.printedOn, [cervezasIp]);
        expect(result.uncertainAreas, ['bar']);
        expect(result.pendingAreas, isEmpty);
        expect(result.dispatchIds.keys, ['cervezas']);

        final queued = (await svc.unsettledActions(biz)).single;
        expect(OfflinePosService.isLocalKitchenRoundClaimed(queued), isFalse);
        expect(queued['area_results'], {
          'cervezas': OfflinePosService.kitchenAreaDelivered,
          'bar': OfflinePosService.kitchenAreaUncertain,
        });
        expect(queued['printed_areas'], ['cervezas']);
        expect(queued['uncertain_areas'], ['bar']);
        final visible = await PendingKitchenPrints.instance.list(biz);
        expect(visible.single.uncertain, isTrue);

        await sync(biz);
        expect(sales.itemConfirms, ['$_order:$_beer']);
        expect(cloud.calls, isEmpty);
      },
    );

    test('[P1] si la marca «imprimiendo» no queda guardada, no sale papel; '
        'la cola imprime cada área una sola vez', () async {
      const biz = 'real-mark-fails';
      OfflinePosService.localPrintClaimTtl = const Duration(milliseconds: 300);
      // Dos impresoras en cervezas: el selector corre justo antes de la marca.
      await cachePrinter(biz, 'cervezas', cervezasIp, secondIp: '10.0.0.21');
      await cachePrinter(biz, 'bar', barIp);
      final thermals = _Thermals(client);
      final printing = PrintingService(
        client,
        printingRepository: thermals,
        salesRepository: sales,
      );

      final result = await printing.sendLocalOrderToKitchen(
        businessId: biz,
        localState: localRound(),
        tableName: 'A26',
        forceChoosePrinter: true,
        choosePrinter: (area, printers, current) async {
          writes.fail = true; // desde aquí la cola no guarda nada
          return null;
        },
      );
      writes.fail = false;
      expect(thermals.printedOn, isEmpty, reason: 'sin marca, sin papel');
      expect(result.pendingAreas, containsAll(['cervezas', 'bar']));

      // El reclamo (que no se pudo soltar) vence y la cola la toma.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await sync(biz);
      expect(cloud.calls.single.excluded, isEmpty);
      expect(cloud.calls.single.only, {_beer, _juice});
      await sync(biz);
      expect(cloud.calls, hasLength(1), reason: 'una sola vez');
    });

    test('[P1] el reclamo vence con el selector abierto: la cola toma la '
        'comanda y el envío local ya no imprime', () async {
      const biz = 'real-claim-expires';
      OfflinePosService.localPrintClaimTtl = const Duration(milliseconds: 50);
      await cachePrinter(biz, 'cervezas', cervezasIp, secondIp: '10.0.0.21');
      await cachePrinter(biz, 'bar', barIp);
      final thermals = _Thermals(client);
      final printing = PrintingService(
        client,
        printingRepository: thermals,
        salesRepository: sales,
      );

      await printing.sendLocalOrderToKitchen(
        businessId: biz,
        localState: localRound(),
        tableName: 'A26',
        forceChoosePrinter: true,
        choosePrinter: (area, printers, current) async {
          // El mesero deja el selector abierto: el reclamo vence y el
          // sincronizador procesa la ronda mientras tanto.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await sync(biz);
          return null;
        },
      );

      expect(cloud.calls.single.only, {_beer, _juice});
      expect(thermals.printedOn, isEmpty, reason: 'nunca imprimen los dos');
      expect(await svc.unsettledActions(biz), isEmpty);
    });

    test('si no se puede registrar la ronda, no sale papel', () async {
      const biz = 'real-no-register';
      await cachePrinter(biz, 'cervezas', cervezasIp);
      await cachePrinter(biz, 'bar', barIp);
      final thermals = _Thermals(client);
      final printing = PrintingService(
        client,
        printingRepository: thermals,
        salesRepository: sales,
      );
      writes.fail = true;
      await expectLater(
        printing.sendLocalOrderToKitchen(
          businessId: biz,
          localState: localRound(),
          tableName: 'A26',
        ),
        throwsA(isA<StateError>()),
      );
      writes.fail = false;
      expect(thermals.printedOn, isEmpty);
    });
  });
}
