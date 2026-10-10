// Replay de una comanda impresa por la LAN ('confirm_local_order'): confirma
// a cocina SOLO las líneas que imprimió (20261010_0002), nunca la orden
// entera (eso pasaba a 'pending' lo agregado después, que quedaba «enviado»
// sin haber salido). Si no puede resolver todas sus líneas, o falta la
// migración, la acción se conserva sin bloquear las demás de su orden; una
// acción de una versión anterior sin ids queda para recuperarla a mano.

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _order = '0b000000-0000-4000-8000-000000000001';
const _printed1 = '1b000000-0000-4000-8000-000000000001';
const _printed2 = '1b000000-0000-4000-8000-000000000002';
const _addedLater = '1b000000-0000-4000-8000-000000000009';

class _Sales extends SalesRepository {
  _Sales(super.client);

  /// false = el servidor todavía no tiene 20261010_0002 (PGRST202).
  bool hasItemsRpc = true;

  /// 'orden:id1,id2' por llamada.
  final itemConfirms = <String>[];
  final wholeOrderConfirms = <String>[];

  /// null = el alta en línea sube; si no, el servidor la rechaza.
  Object? addError;
  final added = <String>[];

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
    final error = addError;
    if (error != null) throw error;
    added.add(menuItemId);
    return (itemId: _addedLater, replayed: false, itemExists: true);
  }
}

/// Áreas que no salieron por la LAN: registra qué pide el replay a la nube.
class _Printing extends PrintingService {
  _Printing(super.client);
  final calls = <({Set<String>? only, Set<String> excludedAreas})>[];

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
    calls.add((only: onlyItemIds, excludedAreas: excludeAreaCodes));
    return const KitchenSendResult(
      dispatchIds: {},
      directAreas: ['bar'],
      escalatedAreas: [],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  late OfflineQueueDb db;
  late SupabaseClient client;
  late _Sales sales;
  late _Printing printing;
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
    client = SupabaseClient('http://localhost:54321', 'test-key');
  });

  tearDownAll(() async {
    await db.close();
    await client.dispose();
  });

  setUp(() {
    service.setHubUploader(null);
    sales = _Sales(client);
    printing = _Printing(client);
  });

  Future<void> enqueueRound(
    String biz,
    Map<String, dynamic>? itemIdsByArea, {
    List<String> printed = const ['kitchen', 'bar'],
    List<String> missing = const [],
  }) => service.enqueueAction(
    businessId: biz,
    action: {
      'id': '$biz-round',
      'type': 'confirm_local_order',
      'order_id': _order,
      'origin': 'table',
      'table_name': 'Mesa 1',
      'item_ids_by_area': ?itemIdsByArea,
      'printed_areas': printed,
      'missing_areas': missing,
    },
  );

  Future<void> enqueueAdd(String biz, String id, String tmpId) =>
      service.enqueueAction(
        businessId: biz,
        action: {
          'id': '$biz-$id',
          'type': 'add_item',
          'order_id': _order,
          'origin': 'table',
          'item_id': tmpId,
          'menu_item_id': 'arroz',
          'qty': 1,
        },
      );

  Future<void> sync(String biz) => service.syncPendingActions(
    businessId: biz,
    salesRepository: sales,
    printingService: printing,
    inventoryRepository: InventoryRepository(client),
    cashierRepository: CashierRepository(client),
    force: true,
  );

  Future<Map<String, dynamic>?> round(String biz) async {
    for (final action in await service.unsettledActions(biz)) {
      if (action['id'] == '$biz-round') return action;
    }
    return null;
  }

  test('confirma solo las líneas impresas, de todas las áreas', () async {
    const biz = 'items-only';
    await enqueueRound(biz, {
      'kitchen': [_printed1],
      'bar': [_printed2],
    });
    await sync(biz);
    expect(sales.itemConfirms, ['$_order:$_printed1,$_printed2']);
    expect(sales.wholeOrderConfirms, isEmpty);
    expect(await service.unsettledActions(biz), isEmpty);
  });

  test('línea temporal cuyo alta terminó durante la impresión: se resuelve '
      'con el mapeo guardado', () async {
    const biz = 'items-renamed';
    await service.rememberKitchenItemMapping(
      businessId: biz,
      localItemId: 'tmp_pollo',
      remoteItemId: _printed2,
      force: true,
    );
    await enqueueRound(biz, {
      'kitchen': [_printed1, 'tmp_pollo'],
    });
    await sync(biz);
    expect(sales.itemConfirms, ['$_order:$_printed1,$_printed2']);
    expect(sales.wholeOrderConfirms, isEmpty);
  });

  test('sin la migración (PGRST202): se conserva con el aviso, sin gastar '
      'intentos y sin confirmar la orden entera', () async {
    const biz = 'items-no-rpc';
    sales.hasItemsRpc = false;
    await enqueueRound(biz, {
      'kitchen': [_printed1],
    });
    await sync(biz);
    final kept = await round(biz);
    expect(kept?['status'], 'failed');
    expect(kept?['attempts'], 0);
    expect(kept?['kitchen_hold'], isTrue);
    expect(kept?['last_error'], contains('Falta actualizar el servidor'));
    expect(sales.itemConfirms, isEmpty);
    expect(sales.wholeOrderConfirms, isEmpty);

    // Aplicada la migración, sube sola.
    sales.hasItemsRpc = true;
    await sync(biz);
    expect(sales.itemConfirms, ['$_order:$_printed1']);
    expect(await round(biz), isNull);
  });

  test('una línea temporal sin mapeo ni alta pendiente: se conserva, gasta '
      'intentos y acaba en dead-letter, nunca confirma la orden entera', () async {
    const biz = 'items-unresolved';
    await enqueueRound(biz, {
      'kitchen': [_printed1, 'tmp_sin_subir'],
    });
    await sync(biz);
    expect((await round(biz))?['attempts'], 1);
    expect((await round(biz))?['status'], 'failed');
    for (var i = 1; i < OfflinePosService.maxAttempts; i++) {
      await sync(biz);
    }
    final dead = await round(biz);
    expect(dead?['status'], 'dead');
    expect(dead?['last_error'], contains('No se pudo identificar'));
    expect(sales.itemConfirms, isEmpty);
    expect(sales.wholeOrderConfirms, isEmpty);
  });

  test('el alta de la línea sigue en la cola detrás de la comanda: la comanda '
      'espera sin gastar intentos y no frena el alta', () async {
    const biz = 'items-wait-add';
    await enqueueRound(biz, {
      'kitchen': [_printed1, 'tmp_arroz'],
    });
    // El alta en línea falló después de imprimir y quedó en la cola.
    await enqueueAdd(biz, 'add', 'tmp_arroz');
    sales.addError = StateError('rechazado por el servidor');
    await sync(biz);
    final waiting = await round(biz);
    expect(waiting?['attempts'], 0);
    expect(waiting?['last_error'], contains('espera que suban'));
    expect(sales.itemConfirms, isEmpty);
    expect(
      (await service.unsettledActions(
        biz,
      )).singleWhere((a) => a['type'] == 'add_item')['attempts'],
      1,
      reason: 'el alta corrió aunque la comanda está antes en la cola',
    );

    // El alta sube y guarda su mapeo; la comanda se confirma después.
    sales.addError = null;
    await sync(biz);
    await sync(biz);
    expect(sales.itemConfirms, ['$_order:$_printed1,$_addedLater']);
    expect(sales.wholeOrderConfirms, isEmpty);
    expect(await service.unsettledActions(biz), isEmpty);
  });

  test('acción de una versión anterior sin ids: va a dead-letter para '
      'recuperarla a mano y no frena lo demás de su orden', () async {
    const biz = 'items-legacy';
    await enqueueRound(biz, null);
    await enqueueAdd(biz, 'after', 'tmp_nuevo');
    await sync(biz);
    final legacy = await round(biz);
    expect(legacy?['status'], 'dead');
    expect(legacy?['last_error'], contains('versión anterior'));
    expect(sales.itemConfirms, isEmpty);
    expect(sales.wholeOrderConfirms, isEmpty);
    expect(sales.added, ['arroz'], reason: 'el alta de la orden siguió');
  });

  test('áreas sin imprimir: la nube imprime y confirma solo las líneas de la '
      'comanda', () async {
    const biz = 'items-missing-area';
    await enqueueRound(
      biz,
      {
        'kitchen': [_printed1],
        'bar': [_printed2],
      },
      printed: ['kitchen'],
      missing: ['bar'],
    );
    await sync(biz);
    expect(printing.calls.single.only, {_printed1, _printed2});
    expect(printing.calls.single.excludedAreas, {'kitchen'});
    expect(sales.wholeOrderConfirms, isEmpty);
    expect(await round(biz), isNull);
  });
}
