// T04 (20261010_0006): las ediciones de la cola offline viajan con la versión
// que veía el operador y un id de operación estable. Respuestas perdidas,
// reintentos, cambios de otro equipo y cambios de la versión anterior de la
// app: ninguno pisa en silencio uno posterior.

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
import 'package:mangopos/data/models/order_edit.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _order = '0e000000-0000-4000-8000-000000000001';
const _item = '0e000000-0000-4000-8000-0000000000a1';

typedef _Sent = ({String kind, Object? value, OrderEdit edit});

/// El servidor: aplica (versión = base + 1) salvo que se le diga otra cosa.
class _Server extends SalesRepository {
  _Server(super.client);

  final sent = <_Sent>[];
  final scripted = <FutureOr<OrderEditResult> Function(OrderEdit edit)>[];

  Future<OrderEditResult> _reply(String kind, Object? value, OrderEdit edit) {
    sent.add((kind: kind, value: value, edit: edit));
    if (scripted.isNotEmpty) {
      return Future.sync(() => scripted.removeAt(0)(edit));
    }
    return Future.value(
      OrderEditResult(status: 'applied', version: (edit.base.version ?? 0) + 1),
    );
  }

  @override
  Future<OrderEditResult> applyItemGroup({
    required String orderId,
    required String opId,
    required List<Map<String, dynamic>> actions,
    bool force = false,
  }) => _reply(
    'group',
    actions,
    OrderEdit(
      orderId: orderId,
      opId: opId,
      base: force ? OrderEditBase.forced : OrderEditBase.ofVersion(null),
    ),
  );

  @override
  Future<OrderEditResult> updateItemQuantity({
    required String itemId,
    required double quantity,
    required OrderEdit edit,
  }) => _reply('qty', quantity, edit);

  @override
  Future<OrderEditResult> updateItemNotes({
    required String itemId,
    required String notes,
    required OrderEdit edit,
  }) => _reply('notes', notes, edit);
}

OrderEditResult _conflict(OrderEdit _) => throw const OrderEditConflict(
  OrderEditResult(
    status: 'conflict',
    reason: 'stale_version',
    version: 9,
    current: {'qty': 4},
  ),
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

  Future<OfflineQueueSyncResult> sync(String biz) => service.syncPendingActions(
    businessId: biz,
    salesRepository: server,
    printingService: PrintingService(client),
    inventoryRepository: InventoryRepository(client),
    cashierRepository: CashierRepository(client),
    force: true,
  );

  Future<void> enqueue(String biz, Map<String, dynamic> action) =>
      service.enqueueAction(
        businessId: biz,
        action: {'order_id': _order, 'item_id': _item, ...action},
      );

  Future<List<Map<String, dynamic>>> unsettled(String biz) =>
      service.unsettledActions(biz);

  test(
    'grupo: respuesta perdida repite una sola transacción con la misma llave',
    () async {
      const biz = 'group-lost-reply';
      final actions = [
        {
          'kind': 'details',
          'item_id': _item,
          'base_version': 5,
          'args': {'qty': 3},
        },
        {
          'kind': 'delete',
          'item_id': '0e000000-0000-4000-8000-0000000000a2',
          'base_version': 1,
        },
      ];
      await enqueue(biz, {
        'id': 'group-1',
        'type': 'edit_item_group',
        'actions': actions,
        'result_items': [],
        'removed_ids': [],
      });
      server.scripted.add((_) => throw TimeoutException('respuesta perdida'));
      await sync(biz);
      expect((await unsettled(biz)).single['actions'], actions);
      await sync(biz);
      expect(server.sent.map((s) => s.kind), ['group', 'group']);
      expect(server.sent[0].edit.opId, server.sent[1].edit.opId);
      expect(server.sent[0].value, server.sent[1].value);
      expect(await unsettled(biz), isEmpty);
    },
  );
  test(
    'grupo: conflicto conserva todo y solo se fuerza por decisión del operador',
    () async {
      const biz = 'group-conflict';
      await enqueue(biz, {
        'id': 'group-conflict-op',
        'type': 'edit_item_group',
        'actions': [
          {
            'kind': 'details',
            'item_id': _item,
            'base_version': 5,
            'args': {'qty': 3},
          },
          {
            'kind': 'delete',
            'item_id': '0e000000-0000-4000-8000-0000000000a2',
            'base_version': 1,
          },
        ],
        'result_items': [],
        'removed_ids': [],
      });
      server.scripted.add(_conflict);
      await sync(biz);
      final pending = (await unsettled(biz)).single;
      expect(pending['status'], 'dead');
      expect(pending['edit_conflict'], true);
      expect(pending['actions'], hasLength(2));
      await service.retryDeadActions(biz);
      await sync(biz);
      expect(server.sent.last.edit.base.force, true);
      expect(await unsettled(biz), isEmpty);
    },
  );
  test(
    'grupo: su versión final se usa en la siguiente edición de la misma línea',
    () async {
      const biz = 'group-rebase';
      await enqueue(biz, {
        'id': 'group-before-qty',
        'type': 'edit_item_group',
        'actions': [
          {
            'kind': 'details',
            'item_id': _item,
            'base_version': 5,
            'args': {'qty': 3},
          },
        ],
        'result_items': [],
        'removed_ids': [],
      });
      await enqueue(biz, {
        'id': 'qty-after-group',
        'type': 'update_item_quantity',
        'quantity': 4,
        'base_version': 5,
      });
      server.scripted.add(
        (_) => const OrderEditResult(status: 'applied', versions: {_item: 8}),
      );
      await sync(biz);
      expect(server.sent.last.edit.base.version, 8);
    },
  );

  test(
    'respuesta perdida: el reintento manda el mismo id de operación',
    () async {
      const biz = 't04-lost-reply';
      await enqueue(biz, {
        'id': 'qty-lost',
        'type': 'update_item_quantity',
        'quantity': 2,
        'base_version': 5,
      });
      server.scripted.add((_) => throw TimeoutException('respuesta perdida'));

      await sync(biz);
      expect(await unsettled(biz), hasLength(1));
      await sync(biz);

      expect(server.sent, hasLength(2));
      expect(server.sent[0].edit.opId, server.sent[1].edit.opId);
      expect(server.sent.map((s) => s.edit.base.version), [5, 5]);
      expect(await unsettled(biz), isEmpty);
    },
  );

  test('otro equipo cambió la línea antes de subir: no se aplica, queda el '
      'conflicto con lo vigente y «Reintentar» lo aplica encima', () async {
    const biz = 't04-replay-conflict';
    await enqueue(biz, {
      'id': 'qty-stale',
      'type': 'update_item_quantity',
      'quantity': 2,
      'base_version': 5,
    });
    server.scripted.add(_conflict);

    await sync(biz);

    final held = (await unsettled(biz)).single;
    expect(held['status'], 'dead');
    expect(held['edit_conflict'], isTrue);
    expect(held['conflict_current'], {'qty': 4});
    expect(held['last_error'], contains('Otro equipo cambió esto'));

    // Una pasada más no lo aplica sola (sin decisión del cajero).
    server.scripted.add(_conflict);
    await sync(biz);
    expect(server.sent.where((s) => s.edit.base.force), isEmpty);

    expect(await service.retryDeadActions(biz), 1);
    await sync(biz);
    final last = server.sent.last;
    expect(last.edit.base.force, isTrue);
    expect(last.value, 2);
    expect(await unsettled(biz), isEmpty);
  });

  test('cambio hecho con la versión anterior de la app (sin versión): no se '
      'aplica solo', () async {
    const biz = 't04-legacy';
    await enqueue(biz, {
      'id': 'qty-legacy',
      'type': 'update_item_quantity',
      'quantity': 7,
    });

    await sync(biz);

    expect(server.sent, isEmpty);
    final held = (await unsettled(biz)).single;
    expect(held['edit_conflict'], isTrue);
    expect(held['last_error'], contains('versión anterior de la app'));

    expect(await service.retryDeadActions(biz), 1);
    await sync(biz);
    expect(server.sent.single.edit.base.force, isTrue);
    expect(await unsettled(biz), isEmpty);
  });

  test('dos cantidades sin red: sube la última, con la versión que se veía '
      'antes de la primera', () async {
    const biz = 't04-compaction';
    await enqueue(biz, {
      'id': 'qty-a',
      'type': 'update_item_quantity',
      'quantity': 2,
      'base_version': 5,
    });
    await enqueue(biz, {
      'id': 'qty-b',
      'type': 'update_item_quantity',
      'quantity': 3,
      'base_version': 6,
    });

    final queued = (await unsettled(
      biz,
    )).where((a) => a['type'] == 'update_item_quantity').single;
    expect(queued['quantity'], 3);
    expect(queued['base_version'], 5);

    await sync(biz);
    expect(server.sent.single.value, 3);
    expect(server.sent.single.edit.base.version, 5);
  });

  test(
    'cambios encadenados de este equipo: el siguiente pasa a la versión '
    'que dejó el anterior; uno de otra versión sigue siendo conflicto',
    () async {
      const biz = 't04-rebase';
      await enqueue(biz, {
        'id': 'qty-own',
        'type': 'update_item_quantity',
        'quantity': 2,
        'base_version': 5,
      });
      await enqueue(biz, {
        'id': 'notes-own',
        'type': 'update_item_notes',
        'notes': 'sin hielo',
        'base_version': 5,
      });

      await sync(biz);

      expect(server.sent.map((s) => s.kind), ['qty', 'notes']);
      expect(server.sent.map((s) => s.edit.base.version), [5, 6]);
      expect(await unsettled(biz), isEmpty);

      const other = 't04-no-rebase';
      await enqueue(other, {
        'id': 'qty-own-2',
        'type': 'update_item_quantity',
        'quantity': 2,
        'base_version': 5,
      });
      await enqueue(other, {
        'id': 'notes-older',
        'type': 'update_item_notes',
        'notes': 'otra',
        'base_version': 4,
      });
      await sync(other);
      expect(server.sent.last.kind, 'notes');
      expect(server.sent.last.edit.base.version, 4);
    },
  );

  test('conflicto que subió por el Hub: queda en cuarentena; «Reintentar» lo '
      'reaplica el Hub encima, nunca la cola local', () async {
    const biz = 't04-hub-conflict';
    await HubConfigService().setDeviceRole(biz, HubDeviceRole.hub);
    Future<OfflineQueueSyncResult> uplink() => service.syncHubOpLog(
      businessId: biz,
      salesRepository: server,
      printingService: PrintingService(client),
      inventoryRepository: InventoryRepository(client),
      cashierRepository: CashierRepository(client),
    );
    Future<List<Map<String, dynamic>>> quarantine() async => [
      for (final a in await unsettled(biz))
        if (a['quarantined_from'] == 'hub_oplog') a,
    ];

    await service.appendToLocalHubOpLog(biz, {
      'id': 'hub-qty-1',
      'type': 'update_item_quantity',
      'order_id': _order,
      'item_id': _item,
      'quantity': 2,
      'base_version': 5,
    });
    server.scripted.add(_conflict);

    await uplink();

    final held = (await quarantine()).single;
    expect(held['id'], 'hub-qty-1');
    expect(held['edit_conflict'], isTrue);
    expect(await service.unsettledHubActions(biz), hasLength(1));

    expect(await service.retryDeadActions(biz), 1);
    // La cola local no la reproduce (no conoce los ids de la caja cliente).
    await sync(biz);
    expect(server.sent, hasLength(1));

    await uplink();
    expect(server.sent, hasLength(2));
    expect(server.sent.last.edit.base.force, isTrue);
    expect(await quarantine(), isEmpty);
    expect(await service.unsettledHubActions(biz), isEmpty);
  });
}
