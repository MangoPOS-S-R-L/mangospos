import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_baseline_service.dart';
import 'package:mangopos/core/offline/hub/hub_op_log.dart';
import 'package:mangopos/core/offline/hub/hub_op_log_dao.dart';
import 'package:mangopos/core/offline/hub/hub_order_projector.dart';
import 'package:mangopos/core/offline/hub/hub_projection_cache.dart';
import 'package:mangopos/core/offline/hub/hub_state_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests del baseline del Hub (paso 6): la foto de las órdenes que YA estaban
/// abiertas antes de que se cayera internet.
///
/// El hueco que cierra: los proyectores solo reconstruyen órdenes CREADAS
/// durante la ventana offline. Una mesa abierta por otra caja mientras había
/// internet se veía ocupada en el grid (por el cache de estado de zonas) pero
/// al abrirla salía VACÍA.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HubStateDb db;
  late HubBaselineService baseline;
  late HubOpLog log;
  late HubProjectionCache cache;
  const biz = 'biz-1';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = HubStateDb.inMemory(NativeDatabase.memory());
    baseline = HubBaselineService(db: db);
    log = HubOpLog(dao: HubOpLogDao(db));
    cache = HubProjectionCache(log: log, baseline: baseline);
  });

  tearDown(() async {
    await db.close();
  });

  /// Siembra una foto sin pasar por Supabase (la captura real necesita red).
  Future<void> sembrarFoto(List<Map<String, dynamic>> ops) async {
    await db.into(db.hubBaseline).insertOnConflictUpdate(
          HubBaselineCompanion.insert(
            businessId: biz,
            capturedAt: DateTime.now().toUtc(),
            opsJson: jsonEncode(HubBaselineService.assignBaselineSeq(ops)),
          ),
        );
  }

  List<Map<String, dynamic>> mesaConItems(
    String orderId,
    String tableId,
    List<String> itemIds,
  ) =>
      [
        {
          'type': 'open_table',
          'order_id': orderId,
          'table_id': tableId,
          'baseline': true,
        },
        for (final id in itemIds)
          {
            'type': 'add_item',
            'order_id': orderId,
            'table_id': tableId,
            'item_id': id,
            'product_name': 'Cerveza',
            'qty': 1,
            'unit_price': 150,
            'baseline': true,
          },
      ];

  group('numeración', () {
    test('assignBaselineSeq numera en negativo conservando el orden', () {
      final ops = HubBaselineService.assignBaselineSeq([
        {'type': 'open_table'},
        {'type': 'add_item'},
        {'type': 'add_item'},
      ]);
      expect(ops.map((o) => o['seq']), [-3, -2, -1]);
    });

    // Es la razón de ser de los negativos: el op-log real numera desde 1, y si
    // la foto usara 1..N las dos series se intercalarían al ordenar.
    test('todo seq del baseline queda por debajo del primer seq del op-log',
        () async {
      await sembrarFoto(mesaConItems('ord-vieja', 'mesa-1', ['i1', 'i2']));
      final ops = await baseline.ops(biz);
      final primerSeqDelLog = 1;
      for (final op in ops) {
        expect(op['seq'], lessThan(primerSeqDelLog));
      }
    });
  });

  group('proyección con baseline', () {
    test('una mesa que solo existe en la foto SÍ aparece con sus ítems',
        () async {
      await sembrarFoto(mesaConItems('ord-vieja', 'mesa-1', ['i1', 'i2']));

      final salon = await cache.salon(biz);
      expect(salon.length, 1);
      expect(salon.single['table_id'], 'mesa-1');
      expect(salon.single['items_count'], 2);
      expect(salon.single['total'], 300);
    });

    test('sin foto, el comportamiento es exactamente el de antes', () async {
      await log.append(biz, {
        'op_id': 'a',
        'type': 'open_table',
        'order_id': 'ord-nueva',
        'table_id': 'mesa-9',
      });
      await log.append(biz, {
        'op_id': 'b',
        'type': 'add_item',
        'order_id': 'ord-nueva',
        'table_id': 'mesa-9',
        'item_id': 'i9',
        'product_name': 'Agua',
        'qty': 1,
        'unit_price': 50,
      });

      final salon = await cache.salon(biz);
      expect(salon.single['table_id'], 'mesa-9');
    });

    test('foto y ops offline conviven: se ven las dos mesas', () async {
      await sembrarFoto(mesaConItems('ord-vieja', 'mesa-1', ['i1']));
      await log.append(biz, {
        'op_id': 'a',
        'type': 'open_table',
        'order_id': 'ord-nueva',
        'table_id': 'mesa-2',
      });
      await log.append(biz, {
        'op_id': 'b',
        'type': 'add_item',
        'order_id': 'ord-nueva',
        'table_id': 'mesa-2',
        'item_id': 'i2',
        'product_name': 'Agua',
        'qty': 1,
        'unit_price': 50,
      });

      final salon = await cache.salon(biz);
      expect(salon.map((t) => t['table_id']).toSet(), {'mesa-1', 'mesa-2'});
    });

    // Lo que de verdad importa del orden: un ítem agregado OFFLINE a una mesa
    // que venía de la foto tiene que sumarse a lo que ya tenía, no reemplazarlo.
    test('un ítem agregado offline se APILA sobre los de la foto', () async {
      await sembrarFoto(mesaConItems('ord-vieja', 'mesa-1', ['i1', 'i2']));
      await log.append(biz, {
        'op_id': 'nuevo',
        'type': 'add_item',
        'order_id': 'ord-vieja',
        'table_id': 'mesa-1',
        'item_id': 'i3',
        'product_name': 'Ron',
        'qty': 1,
        'unit_price': 200,
      });

      final salon = await cache.salon(biz);
      expect(salon.single['items_count'], 3);
      expect(salon.single['total'], 150 + 150 + 200);
    });

    // El caso que rompería si el baseline se numerara 1..N: el delete_item
    // offline se aplicaría ANTES del add_item de la foto y no borraría nada.
    test('borrar offline un ítem que venía de la foto SÍ lo quita', () async {
      await sembrarFoto(mesaConItems('ord-vieja', 'mesa-1', ['i1', 'i2']));
      await log.append(biz, {
        'op_id': 'del',
        'type': 'delete_item',
        'order_id': 'ord-vieja',
        'item_id': 'i1',
      });

      final salon = await cache.salon(biz);
      expect(salon.single['items_count'], 1);
      expect(salon.single['total'], 150);
    });

    test('cobrar offline una mesa de la foto la saca del salón', () async {
      await sembrarFoto(mesaConItems('ord-vieja', 'mesa-1', ['i1']));
      await log.append(biz, {
        'op_id': 'pago',
        'type': 'process_payment',
        'order_id': 'ord-vieja',
        'close_order': true,
      });

      expect(await cache.salon(biz), isEmpty);
    });

    test('el detalle de una mesa de la foto se puede proyectar', () async {
      await sembrarFoto(mesaConItems('ord-vieja', 'mesa-1', ['i1', 'i2']));

      final ops = await cache.ops(biz);
      final order = HubOrderProjector.projectOrder(ops, tableId: 'mesa-1');
      expect(order, isNotNull);
      expect(order!.orderId, 'ord-vieja');
      expect(order.items.length, 2);
    });
  });

  group('ciclo de vida de la foto', () {
    test('ops() devuelve vacío si nunca se capturó', () async {
      expect(await baseline.ops(biz), isEmpty);
      expect(await baseline.capturedAt(biz), isNull);
    });

    test('una foto nueva REEMPLAZA a la anterior, no se acumula', () async {
      await sembrarFoto(mesaConItems('ord-1', 'mesa-1', ['i1']));
      await sembrarFoto(mesaConItems('ord-2', 'mesa-2', ['i2']));

      final salon = await cache.salon(biz);
      expect(salon.length, 1, reason: 'la mesa vieja no debe sobrevivir');
      expect(salon.single['table_id'], 'mesa-2');
    });

    test('una foto nueva invalida el cache de proyección', () async {
      await sembrarFoto(mesaConItems('ord-1', 'mesa-1', ['i1']));
      expect((await cache.salon(biz)).single['table_id'], 'mesa-1');

      // Sin que cambie el op-log: solo la foto.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await sembrarFoto(mesaConItems('ord-2', 'mesa-2', ['i2']));
      expect((await cache.salon(biz)).single['table_id'], 'mesa-2');
    });

    test('clear borra la foto y el salón vuelve a solo el op-log', () async {
      await sembrarFoto(mesaConItems('ord-vieja', 'mesa-1', ['i1']));
      expect((await cache.salon(biz)).length, 1);

      await baseline.clear(biz);
      expect(await cache.salon(biz), isEmpty);
    });

    test('la foto de un negocio no se ve en otro', () async {
      await sembrarFoto(mesaConItems('ord-1', 'mesa-1', ['i1']));
      expect(await baseline.ops('otro-negocio'), isEmpty);
      expect(await cache.salon('otro-negocio'), isEmpty);
    });

    test('un opsJson corrupto no truena: se ignora la foto', () async {
      await db.into(db.hubBaseline).insertOnConflictUpdate(
            HubBaselineCompanion.insert(
              businessId: biz,
              capturedAt: DateTime.now().toUtc(),
              opsJson: 'esto no es json',
            ),
          );
      expect(await baseline.ops(biz), isEmpty);
      expect(await cache.salon(biz), isEmpty);
    });
  });

  // El baseline NO entra al op-log, así que el uplink ni lo ve: no hay forma de
  // que una orden que ya existe en Supabase se vuelva a subir.
  test('la foto no contamina el op-log', () async {
    await sembrarFoto(mesaConItems('ord-vieja', 'mesa-1', ['i1', 'i2']));
    expect(await log.length(biz), 0);
    expect(await log.since(biz), isEmpty);
    expect(
      Value(await log.currentSeq(biz)).value,
      0,
      reason: 'la foto tampoco consume seq del Hub',
    );
  });
}
