// Fase 1 de la guía de cierre (sincronización inmediata): guardar una
// operación pide su subida en el acto, sin esperar al timer de 5 s; lo que
// llega durante otra pasada no se pierde ni se solapa; una comanda retenida
// por un id que se guarda después se destraba sola. Integración real:
// OfflinePosService + SQLite en memoria + OfflineSalesUplink con su drenaje
// de producción; solo los repositorios de red son falsos.

import 'dart:async';

import 'package:drift/drift.dart'
    show ApplyInterceptor, BatchedStatements, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/offline_queue_trace.dart';
import 'package:mangopos/core/offline/offline_queue_work.dart';
import 'package:mangopos/core/offline/offline_sales_uplink.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/shell/offline_sales_uplink_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _order = '0c000000-0000-4000-8000-000000000001';
const _printed = '1c000000-0000-4000-8000-000000000001';
const _late = '1c000000-0000-4000-8000-000000000002';

/// Hace fallar las escrituras de la cola a pedido (S02).
class _WriteFailures extends QueryInterceptor {
  bool fail = false;

  void _check() {
    if (fail) throw StateError('disco lleno');
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _check();
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _check();
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _check();
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    _check();
    return super.runBatched(executor, statements);
  }
}

/// Inventario cuyo replay se puede detener a mitad de pasada y que mide
/// cuántas pasadas lo tocan a la vez.
class _Inventory extends InventoryRepository {
  _Inventory(super.client);

  final replayed = <String>[];
  Completer<void>? gate;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<void> adjustInventory({
    required String businessId,
    required String warehouseId,
    required String itemId,
    required double countedQuantity,
    required String reasonCode,
    String? notes,
    double? costPerUnit,
    bool queueOnNetworkFailure = true,
  }) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      final wait = gate;
      if (wait != null) await wait.future;
      replayed.add(itemId);
    } finally {
      inFlight--;
    }
  }
}

class _Sales extends SalesRepository {
  _Sales(super.client);

  bool hasItemsRpc = true;
  final itemConfirms = <String>[];
  final wholeOrderConfirms = <String>[];

  @override
  Future<void> confirmItemsToKitchen(
    String orderId,
    List<String> itemIds,
  ) async {
    if (!hasItemsRpc) {
      throw const PostgrestException(
        message:
            'Could not find the function '
            'public.fn_confirm_order_items_to_kitchen in the schema cache',
        code: 'PGRST202',
      );
    }
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  final writes = _WriteFailures();
  late OfflineQueueDb db;
  late SupabaseClient client;
  late _Inventory inventory;
  late _Sales sales;
  final svc = OfflinePosService();

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
    inventory = _Inventory(client);
    sales = _Sales(client);
  });

  Future<OfflineQueueSyncResult> sync(String biz, {bool force = false}) =>
      svc.syncPendingActions(
        businessId: biz,
        salesRepository: sales,
        printingService: PrintingService(client),
        inventoryRepository: inventory,
        cashierRepository: CashierRepository(client),
        force: force,
      );

  Future<void> enqueue(
    String biz,
    String itemId, {
    String? orderId,
    String? status,
    int? attempts,
    String? nextRetryAt,
  }) => svc.enqueueAction(
    businessId: biz,
    action: {
      'id': '$biz-$itemId',
      'type': 'inventory_adjust',
      'warehouse_id': 'w1',
      'item_id': itemId,
      'counted_quantity': 5,
      'reason_code': 'correction',
      'order_id': ?orderId,
      'status': ?status,
      'attempts': ?attempts,
      'next_retry_at': ?nextRetryAt,
    },
  );

  /// Uplink de producción para [biz]: avisos de la cola + drenaje real. El
  /// timer es de una hora: si algo sube, no fue por él.
  ({OfflineSalesUplink uplink, List<int> passes}) wireUplink(
    String biz, {
    String? Function()? activeBusinessId,
    bool Function()? isConnected,
    Iterable<Stream<Object?>> extraWakeups = const [],
  }) {
    final passes = <int>[];
    final active = activeBusinessId ?? () => biz;
    final uplink = OfflineSalesUplink(
      connectionStream: const Stream<bool>.empty(),
      isConnected: isConnected ?? () => true,
      interval: const Duration(hours: 1),
      wakeups: [
        queueWorkForActiveBusiness(svc.queueWork, active),
        ...extraWakeups,
      ],
      drain: () => drainReadyOfflineSales(
        activeBusinessId: active,
        whenIdle: svc.whenQueueIdle,
        hasReady: svc.hasActionsReadyToSync,
        sync: () async {
          passes.add(passes.length + 1);
          await sync(biz);
        },
      ),
    );
    return (uplink: uplink, passes: passes);
  }

  /// Deja correr microtareas y E/S de SQLite sin avanzar ningún timer largo.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(done(), isTrue, reason: 'no ocurrió a tiempo');
  }

  test('S01: con la app online e inactiva, encolar sube en el acto, sin '
      'esperar al timer', () async {
    const biz = 's01';
    final wired = wireUplink(biz);
    await settle(); // el disparo de arranque no encuentra nada
    expect(wired.passes, isEmpty);

    await enqueue(biz, 'cerveza');
    await until(() => inventory.replayed.contains('cerveza'));
    expect(wired.passes, [1]);
    expect(await svc.pendingActionsCount(biz), 0);
    wired.uplink.dispose();
  });

  test('S01: el aviso llega después del commit, con el negocio de la '
      'operación y una revisión creciente', () async {
    const biz = 's01-signal';
    final events = <OfflineQueueWork>[];
    final sub = svc.queueWork.listen(events.add);
    final before = svc.acceptedWorkRevision(biz);
    await enqueue(biz, 'a');
    await enqueue(biz, 'b');
    await settle();
    final mine = events.where((e) => e.businessId == biz).toList();
    expect(mine.map((e) => e.reason), [
      OfflineQueueWorkReason.enqueued,
      OfflineQueueWorkReason.enqueued,
    ]);
    expect(mine.map((e) => e.revision), [before + 1, before + 2]);
    // Cuando el observador se entera, la operación ya está en la cola.
    expect(await svc.pendingActionsCount(biz), 2);
    await sub.cancel();
  });

  test('S02: si la escritura durable falla, no hay aviso ni subida', () async {
    const biz = 's02';
    final events = <OfflineQueueWork>[];
    final sub = svc.queueWork.listen(events.add);
    final wired = wireUplink(biz);
    await settle();

    writes.fail = true;
    await expectLater(enqueue(biz, 'perdida'), throwsA(isA<StateError>()));
    writes.fail = false;
    await settle();

    expect(events.where((e) => e.businessId == biz), isEmpty);
    expect(wired.passes, isEmpty);
    expect(inventory.replayed, isNot(contains('perdida')));
    expect(await svc.pendingActionsCount(biz), 0);
    wired.uplink.dispose();
    await sub.cancel();
  });

  test('S03: una operación guardada después de que la pasada leyó la cola '
      'sube en una segunda revisión inmediata, sin solaparse', () async {
    const biz = 's03';
    final wired = wireUplink(biz);
    await settle();

    inventory.gate = Completer<void>();
    await enqueue(biz, 'primera');
    await until(() => inventory.inFlight == 1); // pasada 1 detenida en el RPC
    await enqueue(biz, 'segunda'); // no está en la lista que leyó la pasada 1
    await settle();
    expect(wired.passes, [1]);

    inventory.gate!.complete();
    inventory.gate = null;
    await until(() => inventory.replayed.contains('segunda'));
    expect(inventory.replayed, ['primera', 'segunda']);
    expect(wired.passes, [1, 2]);
    expect(inventory.maxInFlight, 1);
    expect(await svc.pendingActionsCount(biz), 0);
    wired.uplink.dispose();
  });

  test('S04: con otra pasada en curso (no del uplink), el pedido espera a que '
      'termine en vez de perderse', () async {
    const biz = 's04';
    // Pasada de otra entrada (VM, botón, reenvío al Hub) detenida a mitad,
    // arrancada antes de que exista el uplink.
    inventory.gate = Completer<void>();
    await enqueue(biz, 'ajena');
    final external = sync(biz);
    await until(() => inventory.inFlight == 1);
    final wired = wireUplink(biz);
    await settle();

    // Antes: hasActionsReadyToSync decía «nada listo» con la pasada en curso
    // y el aviso de esta alta se perdía hasta el timer.
    await enqueue(biz, 'nueva');
    await settle();
    expect(wired.passes, isEmpty, reason: 'espera, no corre en paralelo');
    inventory.gate!.complete();
    inventory.gate = null;
    await external;
    await until(() => inventory.replayed.contains('nueva'));
    expect(wired.passes, [1]);
    expect(inventory.maxInFlight, 1);
    expect(await svc.pendingActionsCount(biz), 0);
    wired.uplink.dispose();
  });

  test('S04: una llamada directa durante una pasada que no vio la operación '
      'nueva termina después de procesarla', () async {
    const biz = 's04-join';
    inventory.gate = Completer<void>();
    await enqueue(biz, 'vieja');
    final first = sync(biz);
    await until(() => inventory.inFlight == 1);
    await enqueue(biz, 'nueva');

    final joined = sync(biz); // antes devolvía la pasada activa, sin 'nueva'
    inventory.gate!.complete();
    inventory.gate = null;
    await first;
    await joined;
    expect(inventory.replayed, ['vieja', 'nueva']);
    expect(inventory.maxInFlight, 1);
    expect(await svc.pendingActionsCount(biz), 0);
  });

  test('S04: llamada durante una pasada que ya vio todo: devuelve esa misma '
      'pasada, sin otra extra', () async {
    const biz = 's04-same';
    inventory.gate = Completer<void>();
    await enqueue(biz, 'unica');
    final first = sync(biz);
    await until(() => inventory.inFlight == 1);
    final joined = sync(biz);
    expect(identical(joined, first), isTrue);
    inventory.gate!.complete();
    inventory.gate = null;
    await first;
    expect(inventory.replayed, ['unica']);
  });

  test('S05: muchos avisos durante una pasada se juntan; nunca dos pasadas a '
      'la vez ni pasadas vacías en ciclo', () async {
    const biz = 's05';
    final checks = <int>[];
    final passes = <int>[];
    final uplink = OfflineSalesUplink(
      connectionStream: const Stream<bool>.empty(),
      isConnected: () => true,
      interval: const Duration(hours: 1),
      wakeups: [queueWorkForActiveBusiness(svc.queueWork, () => biz)],
      drain: () => drainReadyOfflineSales(
        activeBusinessId: () => biz,
        whenIdle: svc.whenQueueIdle,
        hasReady: (id) {
          checks.add(checks.length);
          return svc.hasActionsReadyToSync(id);
        },
        sync: () async {
          passes.add(passes.length);
          await sync(biz);
        },
      ),
    );
    await settle();
    final checksAtStart = checks.length;

    inventory.gate = Completer<void>();
    await enqueue(biz, 'r0');
    await until(() => inventory.inFlight == 1);
    for (var i = 1; i <= 15; i++) {
      await enqueue(biz, 'r$i');
    }
    await settle();
    inventory.gate!.complete();
    inventory.gate = null;
    await until(() => inventory.replayed.length == 16);
    await settle();

    expect(passes.length, 2, reason: 'una pasada + UNA juntando los 15');
    expect(inventory.maxInFlight, 1);
    // Sin trabajo nuevo, no hay más revisiones: no queda girando.
    final checksAfter = checks.length;
    await settle();
    expect(checks.length, checksAfter);
    expect(checksAfter - checksAtStart, lessThanOrEqualTo(4));
    uplink.dispose();
  });

  test('S06: sin red guarda y no intenta; al reconectar o volver al primer '
      'plano sube en el acto', () async {
    const biz = 's06';
    var online = false;
    final reconnect = StreamController<bool>.broadcast();
    final resume = StreamController<void>.broadcast();
    final passes = <int>[];
    final uplink = OfflineSalesUplink(
      connectionStream: reconnect.stream,
      isConnected: () => online,
      interval: const Duration(hours: 1),
      wakeups: [
        queueWorkForActiveBusiness(svc.queueWork, () => biz),
        resume.stream,
      ],
      drain: () => drainReadyOfflineSales(
        activeBusinessId: () => biz,
        whenIdle: svc.whenQueueIdle,
        hasReady: svc.hasActionsReadyToSync,
        sync: () async {
          passes.add(1);
          await sync(biz);
        },
      ),
    );
    await enqueue(biz, 'sin-red');
    await settle();
    expect(passes, isEmpty);
    expect(await svc.pendingActionsCount(biz), 1, reason: 'queda guardada');

    online = true;
    reconnect.add(true);
    await until(() => inventory.replayed.contains('sin-red'));

    // Reanudar: el sistema pudo congelar los timers; revisa en el acto.
    online = false;
    await enqueue(biz, 'en-pausa');
    await settle();
    online = true;
    resume.add(null);
    await until(() => inventory.replayed.contains('en-pausa'));
    expect(passes.length, 2);
    uplink.dispose();
    await reconnect.close();
    await resume.close();
  });

  test('S07: la pasada que dispara un aviso respeta backoff y dead-letter y '
      'avanza el trabajo independiente, sin force', () async {
    const biz = 's07';
    final wired = wireUplink(biz);
    await settle();
    await enqueue(
      biz,
      'en-backoff',
      orderId: 'orden-a',
      status: 'failed',
      attempts: 1,
      nextRetryAt: DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    );
    await enqueue(
      biz,
      'muerta',
      orderId: 'orden-b',
      status: 'dead',
      attempts: OfflinePosService.maxAttempts,
    );
    await enqueue(biz, 'tras-backoff', orderId: 'orden-a');
    await enqueue(biz, 'independiente', orderId: 'orden-c');
    await until(() => inventory.replayed.contains('independiente'));
    await settle();
    expect(inventory.replayed, ['independiente']);
    final left = {
      for (final a in await svc.unsettledActions(biz)) a['item_id']: a,
    };
    expect(left['en-backoff']?['status'], 'failed');
    expect(left['tras-backoff']?['status'], 'pending');
    expect(left['muerta']?['status'], 'dead');
    wired.uplink.dispose();
  });

  test('bitácora: registra lo guardado, el resultado de cada intento y cada '
      'pasada, para explicar una retención', () async {
    const biz = 'trace-real';
    await enqueue(biz, 'sube');
    await enqueue(
      biz,
      'espera',
      status: 'failed',
      attempts: 1,
      nextRetryAt: DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    );
    await sync(biz);
    final events = await OfflineQueueTrace.instance.read(biz);
    final names = events.map((e) => e['ev']).toList();
    expect(names.where((e) => e == 'guardada'), hasLength(2));
    expect(names, contains('subida'));
    final pass = events.lastWhere((e) => e['ev'] == 'pasada');
    expect(pass['detail'], contains('1 subidas'));
    expect(pass['detail'], contains('1 saltadas'), reason: 'la de backoff');
    expect(pass['detail'], contains('1 pendientes'));
  });

  group('S10: comanda retenida por un id que se guarda después', () {
    Future<void> enqueueRound(String biz, List<String> ids) =>
        svc.enqueueAction(
          businessId: biz,
          action: {
            'id': '$biz-round',
            'type': 'confirm_local_order',
            'order_id': _order,
            'origin': 'table',
            'table_name': 'Mesa 1',
            'item_ids_by_area': {'bar': ids},
            'printed_areas': ['bar'],
            'missing_areas': <String>[],
          },
        );

    Future<Map<String, dynamic>?> round(String biz) async {
      for (final action in await svc.unsettledActions(biz)) {
        if (action['id'] == '$biz-round') return action;
      }
      return null;
    }

    test('se destraba en el acto al guardarse el mapeo y confirma solo sus '
        'productos', () async {
      const biz = 's10';
      await enqueueRound(biz, [_printed, 'tmp_alta_lenta']);
      await sync(biz);
      final held = await round(biz);
      expect(held?['kitchen_hold'], isTrue);
      expect(held?['next_retry_at'], isNotNull);
      expect(held?[OfflinePosService.kitchenHoldWaitingItemsKey], [
        'tmp_alta_lenta',
      ]);
      expect(await svc.hasActionsReadyToSync(biz), isFalse);

      final wired = wireUplink(biz);
      await settle();
      expect(wired.passes, isEmpty, reason: 'sigue en su espera');

      // Termina el alta en línea: el VM guarda tmp_ → id real.
      await svc.rememberKitchenItemMapping(
        businessId: biz,
        localItemId: 'tmp_alta_lenta',
        remoteItemId: _late,
        force: true,
      );
      await until(() => sales.itemConfirms.isNotEmpty);
      expect(sales.itemConfirms, ['$_order:$_printed,$_late']);
      expect(sales.wholeOrderConfirms, isEmpty);
      expect(await round(biz), isNull);
      wired.uplink.dispose();
    });

    test(
      'un mapeo ajeno no suelta su espera, y uno parcial solo la acorta',
      () async {
        const biz = 's10-partial';
        await enqueueRound(biz, ['tmp_a', 'tmp_b']);
        await sync(biz);
        await svc.rememberKitchenItemMapping(
          businessId: biz,
          localItemId: 'tmp_otro',
          remoteItemId: _late,
          force: true,
        );
        var held = await round(biz);
        expect(held?['next_retry_at'], isNotNull);
        expect(held?[OfflinePosService.kitchenHoldWaitingItemsKey], [
          'tmp_a',
          'tmp_b',
        ]);

        await svc.rememberKitchenItemMapping(
          businessId: biz,
          localItemId: 'tmp_a',
          remoteItemId: _printed,
          force: true,
        );
        held = await round(biz);
        expect(held?['next_retry_at'], isNotNull, reason: 'aún falta tmp_b');
        expect(held?[OfflinePosService.kitchenHoldWaitingItemsKey], ['tmp_b']);
        expect(await svc.hasActionsReadyToSync(biz), isFalse);
      },
    );

    test('una retención por otro motivo (falta la migración) conserva su '
        'espera aunque se guarde un mapeo', () async {
      const biz = 's10-no-rpc';
      sales.hasItemsRpc = false;
      await enqueueRound(biz, [_printed]);
      await sync(biz);
      final before = await round(biz);
      expect(before?['next_retry_at'], isNotNull);
      expect(before?[OfflinePosService.kitchenHoldWaitingItemsKey], isNull);

      await svc.rememberKitchenItemMapping(
        businessId: biz,
        localItemId: 'tmp_cualquiera',
        remoteItemId: _late,
        force: true,
      );
      final after = await round(biz);
      expect(after?['next_retry_at'], before?['next_retry_at']);
      expect(await svc.hasActionsReadyToSync(biz), isFalse);
    });
  });

  test('S18: el aviso conserva el negocio de la operación; con otro negocio '
      'abierto no lo sube ni toca sus cuentas', () async {
    const original = 's18-a';
    const opened = 's18-b';
    var active = opened;
    final events = <OfflineQueueWork>[];
    final sub = svc.queueWork.listen(events.add);
    final wired = wireUplink(opened, activeBusinessId: () => active);
    await settle();

    await enqueue(original, 'del-negocio-a'); // termina tras el cambio
    await settle();
    expect(events.last.businessId, original);
    expect(wired.passes, isEmpty);
    expect(inventory.replayed, isEmpty);
    expect(await svc.pendingActionsCount(original), 1, reason: 'se conserva');
    expect(await svc.pendingActionsCount(opened), 0);

    // Al volver al negocio original, su trabajo sí sube.
    active = original;
    await sync(original);
    expect(inventory.replayed, ['del-negocio-a']);
    wired.uplink.dispose();
    await sub.cancel();
  });
}
