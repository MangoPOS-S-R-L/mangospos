import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_op_log.dart';
import 'package:mangopos/core/offline/hub/hub_op_log_dao.dart';
import 'package:mangopos/core/offline/hub/hub_state_db.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests del op-log del Hub sobre SQLite (paso 5a). El contrato tiene que ser
/// IDÉNTICO al de la versión de SharedPreferences que reemplaza: los clientes
/// guardan el último `seq` visto y piden el delta, así que `seq` debe seguir
/// siendo monotónico y contiguo por negocio.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HubStateDb db;
  late HubOpLogDao dao;
  const biz = 'biz-1';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = HubStateDb.inMemory(NativeDatabase.memory());
    dao = HubOpLogDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('contrato de seq', () {
    test('append asigna seq monotónico y contiguo desde 1', () async {
      expect(await dao.append(biz, {'op_id': 'a', 'type': 'add_item'}), 1);
      expect(await dao.append(biz, {'op_id': 'b', 'type': 'add_item'}), 2);
      expect(await dao.append(biz, {'op_id': 'c', 'type': 'delete_item'}), 3);
      expect(await dao.currentSeq(biz), 3);
      expect(await dao.length(biz), 3);
    });

    test('currentSeq de un negocio vacío es 0', () async {
      expect(await dao.currentSeq('nadie'), 0);
      expect(await dao.length('nadie'), 0);
    });

    test('cada negocio lleva su propia numeración', () async {
      expect(await dao.append('biz-a', {'op_id': 'a1'}), 1);
      expect(await dao.append('biz-b', {'op_id': 'b1'}), 1);
      expect(await dao.append('biz-a', {'op_id': 'a2'}), 2);
      expect(await dao.currentSeq('biz-a'), 2);
      expect(await dao.currentSeq('biz-b'), 1);
    });
  });

  group('idempotencia', () {
    test(
      'reenviar la misma op_id devuelve el seq previo y no duplica',
      () async {
        final first = await dao.append(biz, {'op_id': 'a', 'type': 'add_item'});
        final again = await dao.append(biz, {'op_id': 'a', 'type': 'add_item'});
        expect(again, first);
        expect(await dao.length(biz), 1);
      },
    );

    test('acepta `id` como alias de `op_id`', () async {
      final first = await dao.append(biz, {'id': 'x', 'type': 'add_item'});
      final again = await dao.append(biz, {'id': 'x', 'type': 'add_item'});
      expect(again, first);
      expect(await dao.length(biz), 1);
    });

    test(
      'ops SIN op_id no se deduplican (mismo comportamiento que antes)',
      () async {
        await dao.append(biz, {'type': 'add_item'});
        await dao.append(biz, {'type': 'add_item'});
        expect(await dao.length(biz), 2);
      },
    );

    test('la misma op_id en dos negocios distintos no colisiona', () async {
      expect(await dao.append('biz-a', {'op_id': 'igual'}), 1);
      expect(await dao.append('biz-b', {'op_id': 'igual'}), 1);
      expect(await dao.length('biz-a'), 1);
      expect(await dao.length('biz-b'), 1);
    });
  });

  group('since', () {
    test('devuelve el delta ordenado por seq', () async {
      await dao.append(biz, {'op_id': 'a'});
      await dao.append(biz, {'op_id': 'b'});
      await dao.append(biz, {'op_id': 'c'});

      final delta = await dao.since(biz, seq: 1);
      expect(delta.map((e) => e['op_id']), ['b', 'c']);
      expect(delta.map((e) => e['seq']), [2, 3]);
    });

    test('seq 0 devuelve el log completo', () async {
      await dao.append(biz, {'op_id': 'a'});
      await dao.append(biz, {'op_id': 'b'});
      expect((await dao.since(biz)).length, 2);
      expect((await dao.since(biz, seq: 0)).length, 2);
    });

    test('no mezcla negocios', () async {
      await dao.append('biz-a', {'op_id': 'a1'});
      await dao.append('biz-b', {'op_id': 'b1'});
      final delta = await dao.since('biz-a');
      expect(delta.length, 1);
      expect(delta.first['op_id'], 'a1');
    });

    test('la op guardada conserva su payload y gana hub_received_at', () async {
      await dao.append(biz, {
        'op_id': 'a',
        'type': 'add_item',
        'order_id': 'ord-1',
        'qty': 3,
      });
      final op = (await dao.since(biz)).single;
      expect(op['type'], 'add_item');
      expect(op['order_id'], 'ord-1');
      expect(op['qty'], 3);
      expect(op['seq'], 1);
      expect(DateTime.tryParse(op['hub_received_at'].toString()), isNotNull);
    });

    test('respeta un hub_received_at que ya venía en la op', () async {
      await dao.append(biz, {
        'op_id': 'a',
        'hub_received_at': '2026-01-01T00:00:00.000Z',
      });
      final op = (await dao.since(biz)).single;
      expect(op['hub_received_at'], '2026-01-01T00:00:00.000Z');
    });
  });

  group('clear y retainOrders', () {
    test('clear vacía solo el negocio indicado', () async {
      await dao.append('biz-a', {'op_id': 'a1'});
      await dao.append('biz-b', {'op_id': 'b1'});
      await dao.clear('biz-a');
      expect(await dao.length('biz-a'), 0);
      expect(await dao.length('biz-b'), 1);
    });

    test('retainOrders conserva solo las ops de las órdenes vivas', () async {
      await dao.append(biz, {'op_id': 'a', 'order_id': 'viva'});
      await dao.append(biz, {'op_id': 'b', 'order_id': 'cerrada'});
      await dao.append(biz, {'op_id': 'c', 'order_id': 'viva'});

      final quedan = await dao.retainOrders(biz, {'viva'});
      expect(quedan, 2);
      expect((await dao.since(biz)).map((e) => e['op_id']), ['a', 'c']);
    });

    test(
      'retainOrders borra las ops SIN order_id (caja, inventario)',
      () async {
        await dao.append(biz, {'op_id': 'a', 'order_id': 'viva'});
        await dao.append(biz, {'op_id': 'b', 'type': 'cash_transaction'});

        final quedan = await dao.retainOrders(biz, {'viva'});
        expect(quedan, 1);
        expect((await dao.since(biz)).single['op_id'], 'a');
      },
    );

    test('retainOrders con conjunto vacío deja el log limpio', () async {
      await dao.append(biz, {'op_id': 'a', 'order_id': 'x'});
      expect(await dao.retainOrders(biz, <String>{}), 0);
      expect(await dao.length(biz), 0);
    });

    test('retainOrders no toca otros negocios', () async {
      await dao.append('biz-a', {'op_id': 'a1', 'order_id': 'x'});
      await dao.append('biz-b', {'op_id': 'b1', 'order_id': 'y'});
      await dao.retainOrders('biz-a', <String>{});
      expect(await dao.length('biz-b'), 1);
    });

    // Tras podar, el Hub sigue numerando desde donde iba: si `seq` se
    // reiniciara, los clientes que guardaron "voy por el 7" se perderían las
    // ops nuevas 1..7.
    test('la numeración NO se reinicia tras podar', () async {
      await dao.append(biz, {'op_id': 'a', 'order_id': 'viva'});
      await dao.append(biz, {'op_id': 'b', 'order_id': 'cerrada'});
      await dao.retainOrders(biz, {'viva'});
      expect(await dao.append(biz, {'op_id': 'c', 'order_id': 'viva'}), 3);
    });

    test('la numeración NO se reinicia tras clear', () async {
      await dao.append(biz, {'op_id': 'a'});
      await dao.append(biz, {'op_id': 'b'});
      await dao.clear(biz);
      expect(await dao.length(biz), 0);
      expect(await dao.append(biz, {'op_id': 'c'}), 3);
    });

    test('currentSeq no retrocede aunque el log quede vacío', () async {
      await dao.append(biz, {'op_id': 'a'});
      await dao.append(biz, {'op_id': 'b'});
      await dao.clear(biz);
      expect(await dao.currentSeq(biz), 2);
    });

    // El escenario concreto que motivó la marca de agua: la caja iba por el
    // seq 2, el Hub podó, y con `MAX(seq)+1` la op nueva volvía a salir con el
    // 2 → `since(2)` no la devolvía nunca.
    test('tras podar, since(ultimoVisto) SÍ entrega la op nueva', () async {
      await dao.append(biz, {'op_id': 'a', 'order_id': 'viva'});
      await dao.append(biz, {'op_id': 'b', 'order_id': 'cerrada'});
      final ultimoVisto = await dao.currentSeq(biz); // 2

      await dao.retainOrders(biz, {'viva'});
      await dao.append(biz, {'op_id': 'nueva', 'order_id': 'viva'});

      final delta = await dao.since(biz, seq: ultimoVisto);
      expect(delta.map((e) => e['op_id']), ['nueva']);
    });
  });

  // ── Replicación al respaldo (paso 11) ──────────────────────────────────
  //
  // Cuando el Hub acepta una op, el terminal se desentiende y NO la encola
  // local. Esa venta queda en UN SOLO disco: si ese equipo se rompe antes de
  // subir, se pierde y de todas las cajas. Replicar es la única salida segura,
  // porque la idempotencia de este sistema es POR DISPOSITIVO y la BD no tiene
  // llave de idempotencia — dos equipos subiendo la misma op harían venta
  // doble.
  group('replicación al respaldo', () {
    test('conserva el seq del primario en vez de renumerar', () async {
      await dao.appendReplica(biz, {
        'op_id': 'a',
        'seq': 7,
        'type': 'add_item',
      });
      final op = (await dao.since(biz)).single;
      expect(op['seq'], 7);
      expect(op['op_id'], 'a');
    });

    // Si el respaldo renumerara desde 1, al promoverlo repartiría `seq` que el
    // primario ya había entregado y los clientes se perderían ops.
    test('la marca de agua sube con lo replicado', () async {
      await dao.appendReplica(biz, {'op_id': 'a', 'seq': 7});
      expect(await dao.currentSeq(biz), 7);
      expect(await dao.append(biz, {'op_id': 'propia'}), 8);
    });

    test('replicar dos veces no duplica', () async {
      expect(await dao.appendReplica(biz, {'op_id': 'a', 'seq': 3}), isTrue);
      expect(await dao.appendReplica(biz, {'op_id': 'a', 'seq': 3}), isFalse);
      expect(await dao.length(biz), 1);
    });

    test('una réplica sin seq se ignora, no truena', () async {
      expect(await dao.appendReplica(biz, {'op_id': 'a'}), isFalse);
      expect(await dao.length(biz), 0);
    });

    test('replicar fuera de orden deja el log ordenado por seq', () async {
      await dao.appendReplica(biz, {'op_id': 'c', 'seq': 3});
      await dao.appendReplica(biz, {'op_id': 'a', 'seq': 1});
      await dao.appendReplica(biz, {'op_id': 'b', 'seq': 2});
      expect((await dao.since(biz)).map((e) => e['op_id']), ['a', 'b', 'c']);
    });

    test('conserva el order_id para que la poda funcione igual', () async {
      await dao.appendReplica(biz, {
        'op_id': 'a',
        'seq': 1,
        'order_id': 'viva',
      });
      await dao.appendReplica(biz, {
        'op_id': 'b',
        'seq': 2,
        'order_id': 'cerrada',
      });
      expect(await dao.retainOrders(biz, {'viva'}), 1);
    });

    test(
      'el respaldo puede proyectar lo replicado (es un log válido)',
      () async {
        await dao.appendReplica(biz, {
          'op_id': 'a',
          'seq': 1,
          'type': 'open_table',
          'order_id': 'o1',
          'table_id': 't1',
        });
        final ops = await dao.since(biz);
        expect(ops.single['type'], 'open_table');
        expect(ops.single['table_id'], 't1');
      },
    );
  });

  group('migración desde SharedPreferences', () {
    test(
      'importa el op-log legacy la primera vez y borra la llave vieja',
      () async {
        final storage = await StorageService.getInstance();
        await storage.writeList(debugHubOpLogKey(biz), [
          {'op_id': 'vieja-1', 'seq': 1, 'order_id': 'ord-1'},
          {'op_id': 'vieja-2', 'seq': 2, 'order_id': 'ord-1'},
        ]);

        expect(await dao.length(biz), 2, reason: 'debe haber importado');
        expect((await dao.since(biz)).map((e) => e['op_id']), [
          'vieja-1',
          'vieja-2',
        ]);
        expect(
          await storage.readList(debugHubOpLogKey(biz)),
          anyOf(isNull, isEmpty),
          reason: 'la llave legacy debe quedar borrada',
        );
      },
    );

    test('la numeración continúa después de lo importado', () async {
      final storage = await StorageService.getInstance();
      await storage.writeList(debugHubOpLogKey(biz), [
        {'op_id': 'vieja-1', 'seq': 1},
        {'op_id': 'vieja-2', 'seq': 2},
      ]);

      expect(await dao.append(biz, {'op_id': 'nueva'}), 3);
    });

    test(
      'una op_id que ya estaba en el legacy sigue siendo idempotente',
      () async {
        final storage = await StorageService.getInstance();
        await storage.writeList(debugHubOpLogKey(biz), [
          {'op_id': 'vieja-1', 'seq': 1},
        ]);

        expect(await dao.append(biz, {'op_id': 'vieja-1'}), 1);
        expect(await dao.length(biz), 1);
      },
    );

    test('sin llave legacy no pasa nada', () async {
      expect(await dao.length(biz), 0);
      expect(await dao.append(biz, {'op_id': 'a'}), 1);
    });
  });

  group('facade HubOpLog', () {
    test('con dao inyectado usa SQLite y respeta el contrato', () async {
      final log = HubOpLog(dao: dao);
      expect(await log.append(biz, {'op_id': 'a'}), 1);
      expect(await log.append(biz, {'op_id': 'a'}), 1); // idempotente
      expect(await log.currentSeq(biz), 1);
      expect(await log.length(biz), 1);
      expect((await log.since(biz)).single['op_id'], 'a');
    });

    test('con storage inyectado sigue usando SharedPreferences', () async {
      final storage = await StorageService.getInstance();
      await storage.write(debugHubOpLogKey('biz-sp'), '[]');
      final log = HubOpLog(storage: storage);

      expect(await log.append('biz-sp', {'op_id': 'a'}), 1);
      expect(await log.length('biz-sp'), 1);

      // La prueba de que fue por SharedPreferences: la llave legacy quedó
      // escrita. (No se comprueba con el dao: si se le pregunta, importa esa
      // misma llave y la respuesta deja de significar nada.)
      final raw = await storage.readList(debugHubOpLogKey('biz-sp'));
      expect(raw, isNotNull);
      expect(raw!.length, 1);
      expect((raw.first as Map)['op_id'], 'a');
    });
  });
}
