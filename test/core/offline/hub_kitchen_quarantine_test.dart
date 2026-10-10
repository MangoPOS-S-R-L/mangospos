// Comanda del op-log del Hub que no se confirma sola (versión anterior, sin
// los ids de sus productos). Antes el Hub la daba por completada sin haber
// hecho el envío: no se veía en ningún lado y, al cerrarse la orden, el
// op-log y su réplica la borraban. Ahora queda en una cuarentena durable:
// dead-letter visible en la cola de este equipo, sin darse por subida, con su
// orden conservada en el op-log hasta que «Limpiar cola» la respalde.

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_state_db.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _biz = 'hub-kitchen-quarantine';
const _order = '0d000000-0000-4000-8000-000000000001';

/// Registra todo lo que el replay le pide al servidor.
class _Sales extends SalesRepository {
  _Sales(super.client);
  final calls = <String>[];

  @override
  Future<void> confirmItemsToKitchen(
    String orderId,
    List<String> itemIds,
  ) async => calls.add('confirmItems:$orderId');

  @override
  Future<({bool merged, DateTime roundStamp})> sendToKitchen(
    String orderId, {
    bool allowMerge = true,
  }) async {
    calls.add('sendToKitchen:$orderId');
    return (merged: false, roundStamp: DateTime(2026, 10, 10));
  }

  @override
  Future<String> voidOrderIfUnpaid(String orderId) async {
    calls.add('void:$orderId');
    return 'voided';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  late OfflineQueueDb db;
  late HubStateDb hubDb;
  late SupabaseClient client;
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
    // La lease del Hub es de este equipo; lo demás responde vacío.
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
    await HubConfigService().setDeviceRole(_biz, HubDeviceRole.hub);
  });

  tearDownAll(() async {
    await db.close();
    await hubDb.close();
    await client.dispose();
    await Supabase.instance.dispose();
  });

  test('comanda antigua sin ids en el Hub: cuarentena durable, visible, sin '
      'darse por subida, conservada aunque la orden cierre, y resuelta solo '
      'a mano', () async {
    final sales = _Sales(client);
    Future<OfflineQueueSyncResult> uplink() => service.syncHubOpLog(
      businessId: _biz,
      salesRepository: sales,
      printingService: PrintingService(client),
      inventoryRepository: InventoryRepository(client),
      cashierRepository: CashierRepository(client),
    );
    Future<Set<String>> pendingInHub() async => {
      for (final op in await service.unsettledHubActions(_biz))
        op['id'].toString(),
    };
    Future<List<Map<String, dynamic>>> quarantine() async => [
      for (final a in await service.unsettledActions(_biz))
        if (a['quarantined_from'] == 'hub_oplog') a,
    ];

    // Comanda de una caja con versión anterior (sin item_ids_by_area) y,
    // después, la anulación de su orden.
    await service.appendToLocalHubOpLog(_biz, {
      'id': 'hub-round-1',
      'type': 'confirm_local_order',
      'order_id': _order,
      'table_name': 'Mesa 9',
      'printed_areas': ['kitchen'],
      'missing_areas': [],
    });
    await service.appendToLocalHubOpLog(_biz, {
      'id': 'hub-void-1',
      'type': 'void_order',
      'order_id': _order,
    });

    final result = await uplink();

    // No se confirmó nada en cocina; la anulación sí subió.
    expect(sales.calls, ['void:$_order']);
    // Visible: cuarentena en la cola de este equipo y conflicto en el resultado.
    final held = await quarantine();
    expect(held, hasLength(1));
    expect(held.single['id'], 'hub-round-1');
    expect(held.single['status'], 'dead');
    expect(held.single['kitchen_hold'], isTrue);
    expect(held.single['last_error'], contains('versión anterior'));
    expect(result.conflicts.map((c) => c.actionId), contains('hub-round-1'));
    expect(await service.deadActionsCount(_biz), 1);
    // No se dio por subida y el op-log la conserva aunque la orden cerró.
    expect(await pendingInHub(), {'hub-round-1'});
    expect(await service.pendingHubUplinkCount(_biz), 1);

    // Otra subida: ni la repite ni la duplica.
    await uplink();
    expect(sales.calls, ['void:$_order']);
    expect(await quarantine(), hasLength(1));
    expect(await pendingInHub(), {'hub-round-1'});

    // Ni «Sincronizar ahora» ni «Reintentar» la reproducen por la cola local
    // (podría crear la orden de una caja cliente en el servidor).
    await service.syncPendingActions(
      businessId: _biz,
      salesRepository: sales,
      printingService: PrintingService(client),
      inventoryRepository: InventoryRepository(client),
      cashierRepository: CashierRepository(client),
      force: true,
    );
    expect(await service.retryDeadActions(_biz), 0);
    expect(sales.calls, ['void:$_order']);
    expect((await quarantine()).single['status'], 'dead');

    // «Limpiar cola» la respalda y la da por resuelta: el op-log la suelta.
    expect(await service.clearPendingActions(_biz, discardedBy: 'Dueño'), 1);
    expect(
      (await service.discardedActionsBackup(_biz)).map((a) => a['id']),
      contains('hub-round-1'),
    );
    await uplink();
    expect(await quarantine(), isEmpty);
    expect(await pendingInHub(), isEmpty);
    expect(await service.pendingHubUplinkCount(_biz), 0);
    expect(sales.calls, ['void:$_order']);
  });
}
