import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Quitar (o bajar la cantidad de) algo que la comanda ya imprimió sin red
/// tiene que llegar al servidor como tal: allí se registra y se le avisa al
/// dueño (20261007_0001). Antes de la cocina, la cola puede seguir fundiendo
/// el alta con el borrado como si nunca hubiera existido.
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

  // El id de la cola es la llave primaria GLOBAL (en producción, un uuid):
  // se prefija con el negocio para que los tests no choquen entre sí.
  Future<List<String>> enqueueAll(
    String biz,
    List<Map<String, dynamic>> actions,
  ) async {
    for (final action in actions) {
      await service.enqueueAction(
        businessId: biz,
        action: {...action, 'id': '$biz-${action['id']}'},
      );
    }
    return (await service.unsettledActions(
      biz,
    )).map((a) => a['id'].toString().substring(biz.length + 1)).toList();
  }

  Map<String, dynamic> add(String id, String item) => {
    'id': id,
    'type': 'add_item',
    'order_id': 'local-order-1',
    'item_id': item,
    'qty': 3,
  };
  Map<String, dynamic> send(String id) => {
    'id': id,
    'type': 'send_to_kitchen',
    'order_id': 'local-order-1',
    'printed_areas': ['kitchen'],
    'missing_areas': [],
  };
  Map<String, dynamic> qty(String id, String item, double q) => {
    'id': id,
    'type': 'update_item_quantity',
    'order_id': 'local-order-1',
    'item_id': item,
    'quantity': q,
  };
  Map<String, dynamic> delete(String id, String item) => {
    'id': id,
    'type': 'delete_item',
    'order_id': 'local-order-1',
    'item_id': item,
    'reason': 'Cliente cambió',
  };

  test('borrar antes de enviar a cocina: se funde con el alta', () async {
    expect(
      await enqueueAll('draft-delete', [
        add('a', 'tmp_1'),
        delete('d', 'tmp_1'),
      ]),
      isEmpty,
    );
  });

  test('bajar cantidad antes de enviar: se funde con el alta', () async {
    const biz = 'draft-qty';
    expect(await enqueueAll(biz, [add('a', 'tmp_1'), qty('q', 'tmp_1', 1)]), [
      'a',
    ]);
    final actions = await service.unsettledActions(biz);
    expect(actions.single['qty'], 1);
  });

  test('borrar después de enviar a cocina: viaja al servidor', () async {
    expect(
      await enqueueAll('sent-delete', [
        add('a', 'tmp_1'),
        send('s'),
        delete('d', 'tmp_1'),
      ]),
      ['a', 's', 'd'],
    );
  });

  test('confirmar orden local cuenta como envío a cocina', () async {
    expect(
      await enqueueAll('sent-confirm', [
        add('a', 'tmp_1'),
        {
          'id': 'c',
          'type': 'confirm_local_order',
          'order_id': 'local-order-1',
          'printed_areas': [],
          'missing_areas': ['kitchen'],
        },
        qty('q', 'tmp_1', 1),
      ]),
      ['a', 'c', 'q'],
    );
  });

  test('bajar cantidad después de enviar: viaja al servidor', () async {
    const biz = 'sent-qty';
    expect(
      await enqueueAll(biz, [
        add('a', 'tmp_1'),
        send('s'),
        qty('q', 'tmp_1', 1),
      ]),
      ['a', 's', 'q'],
    );
    final actions = await service.unsettledActions(biz);
    expect(
      actions.first['qty'],
      3,
      reason: 'el alta conserva lo que se imprimió',
    );
  });

  test(
    'una cantidad de después del envío no reemplaza a una de antes',
    () async {
      const biz = 'real-item';
      expect(
        await enqueueAll(biz, [
          qty('q1', 'item-real', 4),
          send('s'),
          qty('q2', 'item-real', 1),
        ]),
        ['q1', 's', 'q2'],
      );
    },
  );

  test('cantidades seguidas sin envío en medio: se siguen fundiendo', () async {
    expect(
      await enqueueAll('real-item-merge', [
        qty('q1', 'item-real', 2),
        qty('q2', 'item-real', 1),
      ]),
      ['q2'],
    );
  });
}
