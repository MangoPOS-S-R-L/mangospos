// Salidas / Mermas: una salida NUNCA se descuenta dos veces.
//
// El caso que esto cierra: el guardado llega al servidor, pero la respuesta
// se pierde (timeout de 30 s). Antes, el repositorio probaba OTRA función en
// línea y también encolaba — el mismo pote de leche se restaba dos veces.
// Ahora cada salida lleva su llave (`p_reference_id`), un error de red no
// dispara un segundo intento en línea y la cola reenvía con la misma llave.
//
// Gastables (20260930_0051): el consumo interno lleva el ÁREA a la que fue.
// Viaja como `p_destination` solo si la hay; un servidor sin la 0051 no conoce
// ni el parámetro ni el motivo, y la salida cae al `waste` de siempre con el
// área en la nota — nunca se queda sin registrar.

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Cliente de Supabase cuyo HTTP responde lo que diga [handler] y anota cada
/// RPC que se intentó (nombre + cuerpo).
class _Rpc {
  _Rpc(this.handler);

  final Future<http.Response> Function(String fn, Map<String, dynamic> body)
  handler;
  final calls = <({String fn, Map<String, dynamic> body})>[];

  late final SupabaseClient client = SupabaseClient(
    'http://localhost:54321',
    'outflow-test-key',
    httpClient: MockClient((req) async {
      final path = req.url.path;
      final fn = path.contains('/rpc/') ? path.split('/rpc/').last : path;
      final body = req.body.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(req.body) as Map);
      calls.add((fn: fn, body: body));
      final res = await handler(fn, body);
      // PostgREST lee el método de la petición original desde la respuesta.
      return http.Response(
        res.body,
        res.statusCode,
        headers: res.headers,
        request: req,
      );
    }),
  );
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  late OfflineQueueDb db;
  final service = OfflinePosService();

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
  });
  tearDownAll(() async {
    await db.close();
  });
  setUp(() => service.setHubUploader(null));

  Future<void> outflow(
    InventoryRepository repo, {
    required String businessId,
    required String operationId,
  }) => repo.recordOutflow(
    businessId: businessId,
    warehouseId: 'wh-1',
    itemId: 'item-leche',
    quantity: 2.5,
    reasonCode: 'expiration',
    reasonLabel: 'Vencido',
    notes: 'nevera 2',
    costPerUnit: 50,
    operationId: operationId,
  );

  test('la salida manda su llave, el costo y la nota con el motivo', () async {
    final rpc = _Rpc((fn, _) async => _json({'id': 'mov-1', 'replayed': false}));
    try {
      await outflow(
        InventoryRepository(rpc.client),
        businessId: 'biz-ok',
        operationId: 'op-1',
      );
      expect(rpc.calls, hasLength(1));
      final call = rpc.calls.single;
      expect(call.fn, 'fn_inventory_record_outflow');
      expect(call.body['p_reference_id'], 'op-1');
      expect(call.body['p_cost_per_unit'], 50);
      expect(call.body['p_reason_code'], 'expiration');
      expect(call.body['p_notes'], 'Vencido — nevera 2');
      // Sin área no se manda el parámetro: un servidor viejo no lo conoce.
      expect(call.body.containsKey('p_destination'), isFalse);
    } finally {
      await rpc.client.dispose();
    }
  });

  Future<void> internalUse(
    InventoryRepository repo, {
    required String businessId,
    required String operationId,
  }) => repo.recordOutflow(
    businessId: businessId,
    warehouseId: 'wh-1',
    itemId: 'item-papel',
    quantity: 12,
    reasonCode: 'internal_use',
    reasonLabel: 'Consumo interno',
    notes: 'planta alta',
    costPerUnit: 20,
    operationId: operationId,
    destination: '  Baños ',
  );

  test('el consumo interno manda el área, recortada', () async {
    final rpc = _Rpc((fn, _) async => _json({'id': 'mov-9', 'replayed': false}));
    try {
      await internalUse(
        InventoryRepository(rpc.client),
        businessId: 'biz-area',
        operationId: 'op-9',
      );
      final body = rpc.calls.single.body;
      expect(body['p_reason_code'], 'internal_use');
      expect(body['p_destination'], 'Baños');
      expect(body['p_notes'], 'Consumo interno — planta alta');
    } finally {
      await rpc.client.dispose();
    }
  });

  test('servidor sin la 0051: el motivo nuevo cae al waste de siempre, con el '
      'área en la nota y la MISMA llave', () async {
    final rpc = _Rpc((fn, _) async {
      if (fn == 'fn_inventory_record_outflow') {
        return _json({
          'code': 'P0001',
          'message': 'INVALID_OUTFLOW_REASON: internal_use',
          'details': null,
          'hint': null,
        }, 400);
      }
      return _json({'id': 'mov-10'});
    });
    try {
      await internalUse(
        InventoryRepository(rpc.client),
        businessId: 'biz-old-server',
        operationId: 'op-10',
      );
      expect(rpc.calls.map((c) => c.fn), [
        'fn_inventory_record_outflow',
        'fn_inventory_record_movement',
      ]);
      final legacy = rpc.calls.last.body;
      expect(legacy['p_reference_id'], 'op-10');
      expect(legacy['p_movement_type'], 'waste');
      expect(legacy['p_notes'], 'Consumo interno — Para Baños · planta alta');
    } finally {
      await rpc.client.dispose();
    }
  });

  test('un timeout encola el consumo interno CON el área', () async {
    const biz = 'biz-area-timeout';
    final rpc = _Rpc((fn, _) async {
      throw TimeoutException('respuesta perdida tras 30 s');
    });
    try {
      await internalUse(
        InventoryRepository(rpc.client),
        businessId: biz,
        operationId: 'op-11',
      );
      final action = (await service.unsettledActions(biz)).single;
      expect(action['reason_code'], 'internal_use');
      expect(action['destination'], 'Baños');
      expect(action['notes'], 'Consumo interno — planta alta');
    } finally {
      await rpc.client.dispose();
    }
  });

  test('la nota de respaldo pone el área después del motivo', () {
    expect(
      InventoryRepository.notesWithDestination('Consumo interno', 'Baños'),
      'Consumo interno — Para Baños',
    );
    expect(
      InventoryRepository.notesWithDestination(
        'Consumo interno — planta alta',
        'Baños',
      ),
      'Consumo interno — Para Baños · planta alta',
    );
    expect(
      InventoryRepository.notesWithDestination('Vencido — nevera', ''),
      'Vencido — nevera',
    );
  });

  test('sin la función en el servidor cae al waste de siempre con la MISMA '
      'llave', () async {
    final rpc = _Rpc((fn, _) async {
      if (fn == 'fn_inventory_record_outflow') {
        return _json({
          'code': 'PGRST202',
          'message': 'Could not find the function',
          'details': null,
          'hint': null,
        }, 404);
      }
      return _json({'id': 'mov-2'});
    });
    try {
      await outflow(
        InventoryRepository(rpc.client),
        businessId: 'biz-legacy',
        operationId: 'op-2',
      );
      expect(rpc.calls.map((c) => c.fn), [
        'fn_inventory_record_outflow',
        'fn_inventory_record_movement',
      ]);
      final legacy = rpc.calls.last.body;
      expect(legacy['p_reference_id'], 'op-2');
      expect(legacy['p_movement_type'], 'waste');
      expect(legacy['p_reference_type'], 'manual_outflow');
      expect(legacy['p_notes'], 'Vencido — nevera 2');
    } finally {
      await rpc.client.dispose();
    }
  });

  test('un timeout NO dispara otro intento en línea: se encola con la misma '
      'llave y el motivo', () async {
    const biz = 'biz-timeout';
    final rpc = _Rpc((fn, _) async {
      throw TimeoutException('respuesta perdida tras 30 s');
    });
    try {
      await outflow(
        InventoryRepository(rpc.client),
        businessId: biz,
        operationId: 'op-3',
      );
      // Un solo intento: el guardado pudo haber quedado en el servidor.
      expect(rpc.calls, hasLength(1));
      final queued = await service.unsettledActions(biz);
      expect(queued, hasLength(1));
      final action = queued.single;
      expect(action['type'], 'inventory_movement');
      expect(action['movement_type'], 'waste');
      expect(action['reference_type'], 'manual_outflow');
      expect(action['reference_id'], 'op-3');
      expect(action['reason_code'], 'expiration');
      expect(action['notes'], 'Vencido — nevera 2');
    } finally {
      await rpc.client.dispose();
    }
  });

  test('la cola reenvía por la función de salidas, con la misma llave y sin '
      'repetir el motivo en la nota', () async {
    const biz = 'biz-replay';
    await service.enqueueAction(
      businessId: biz,
      action: {
        'id': 'queued-outflow',
        'type': 'inventory_movement',
        'warehouse_id': 'wh-1',
        'item_id': 'item-leche',
        'movement_type': 'waste',
        'quantity': 2.5,
        'cost_per_unit': 50,
        'notes': 'Vencido — nevera 2',
        'reference_type': 'manual_outflow',
        'reference_id': 'op-4',
        'reason_code': 'expiration',
      },
    );
    final rpc = _Rpc((fn, _) async => _json({'id': 'mov-4', 'replayed': true}));
    try {
      final result = await service.syncPendingActions(
        businessId: biz,
        salesRepository: SalesRepository(rpc.client),
        printingService: PrintingService(rpc.client),
        inventoryRepository: InventoryRepository(rpc.client),
        cashierRepository: CashierRepository(rpc.client),
        force: true,
      );
      expect(result.completed, 1);
      final outflows =
          rpc.calls.where((c) => c.fn == 'fn_inventory_record_outflow');
      expect(outflows, hasLength(1));
      final body = outflows.single.body;
      expect(body['p_reference_id'], 'op-4');
      expect(body['p_reason_code'], 'expiration');
      expect(body['p_notes'], 'Vencido — nevera 2');
      expect(
        rpc.calls.where((c) => c.fn == 'fn_inventory_record_movement'),
        isEmpty,
      );
    } finally {
      await rpc.client.dispose();
    }
  });

  test('la cola reenvía el área de un consumo interno', () async {
    const biz = 'biz-replay-area';
    await service.enqueueAction(
      businessId: biz,
      action: {
        'id': 'queued-internal-use',
        'type': 'inventory_movement',
        'warehouse_id': 'wh-1',
        'item_id': 'item-papel',
        'movement_type': 'waste',
        'quantity': 12,
        'cost_per_unit': 20,
        'notes': 'Consumo interno — planta alta',
        'reference_type': 'manual_outflow',
        'reference_id': 'op-12',
        'reason_code': 'internal_use',
        'destination': 'Baños',
      },
    );
    final rpc = _Rpc((fn, _) async => _json({'id': 'mov-12'}));
    try {
      final result = await service.syncPendingActions(
        businessId: biz,
        salesRepository: SalesRepository(rpc.client),
        printingService: PrintingService(rpc.client),
        inventoryRepository: InventoryRepository(rpc.client),
        cashierRepository: CashierRepository(rpc.client),
        force: true,
      );
      expect(result.completed, 1);
      final body = rpc.calls
          .singleWhere((c) => c.fn == 'fn_inventory_record_outflow')
          .body;
      expect(body['p_reference_id'], 'op-12');
      expect(body['p_reason_code'], 'internal_use');
      expect(body['p_destination'], 'Baños');
      expect(body['p_notes'], 'Consumo interno — planta alta');
    } finally {
      await rpc.client.dispose();
    }
  });
}
