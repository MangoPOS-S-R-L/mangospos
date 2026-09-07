import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_op_log.dart';
import 'package:mangopos/core/offline/hub/hub_op_log_dao.dart';
import 'package:mangopos/core/offline/hub/hub_projection_cache.dart';
import 'package:mangopos/core/offline/hub/hub_state_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests de la memoización del op-log del Hub (paso 5b).
///
/// Lo que se protege: con N cajas conectadas, cada op difundida por WebSocket
/// hace que las N pidan `/hub/salon` a la vez. Sin memo, el Hub lee y pliega el
/// log completo N veces POR OP.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HubStateDb db;
  late HubOpLog log;
  late _CountingLog counting;
  late HubProjectionCache cache;
  const biz = 'biz-1';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = HubStateDb.inMemory(NativeDatabase.memory());
    log = HubOpLog(dao: HubOpLogDao(db));
    counting = _CountingLog(log);
    cache = HubProjectionCache(log: counting);
  });

  tearDown(() async {
    await db.close();
  });

  /// Abre una mesa CON un ítem: `projectSalon` excluye las mesas sin ítems
  /// vivos (hub_order_projector.dart:61), así que un `open_table` a secas no
  /// aparecería en el salón.
  Future<void> abrirMesa(
    String orderId,
    String tableId, {
    String businessId = biz,
  }) async {
    await log.append(businessId, {
      'op_id': 'open-$orderId',
      'type': 'open_table',
      'order_id': orderId,
      'table_id': tableId,
    });
    await log.append(businessId, {
      'op_id': 'item-$orderId',
      'type': 'add_item',
      'order_id': orderId,
      'table_id': tableId,
      'item_id': 'i-$orderId',
      'product_name': 'Cerveza',
      'product_price': 150,
      'qty': 1,
    });
  }

  test('sin cambios en el log, las lecturas repetidas no vuelven a leer',
      () async {
    await abrirMesa('ord-1', 'mesa-1');

    await cache.salon(biz);
    final lecturasTrasPrimera = counting.sinceCalls;

    for (var i = 0; i < 10; i++) {
      await cache.salon(biz);
    }

    expect(counting.sinceCalls, lecturasTrasPrimera,
        reason: '10 peticiones más no deben tocar el log');
  });

  test('N peticiones SIMULTÁNEAS tras una op comparten un solo cálculo',
      () async {
    await abrirMesa('ord-1', 'mesa-1');
    await cache.salon(biz); // calienta
    final antes = counting.sinceCalls;

    // Llega una op nueva: es el momento en que las N cajas piden a la vez.
    await abrirMesa('ord-2', 'mesa-2');

    final resultados = await Future.wait([
      cache.salon(biz),
      cache.salon(biz),
      cache.salon(biz),
      cache.salon(biz),
      cache.salon(biz),
    ]);

    expect(counting.sinceCalls - antes, 1,
        reason: '5 cajas a la vez → una sola lectura del log');
    for (final r in resultados) {
      expect(r.length, 2);
    }
  });

  test('una op nueva sí invalida: el salón refleja la mesa nueva', () async {
    await abrirMesa('ord-1', 'mesa-1');
    expect((await cache.salon(biz)).length, 1);

    await abrirMesa('ord-2', 'mesa-2');
    final salon = await cache.salon(biz);
    expect(salon.length, 2);
    expect(
      salon.map((t) => t['table_id']).toSet(),
      {'mesa-1', 'mesa-2'},
    );
  });

  // El caso que obliga a que la revisión mire también `length`: `retainOrders`
  // borra filas pero NO mueve la marca de agua, así que con `currentSeq` sola
  // el cache seguiría sirviendo mesas ya cerradas.
  test('una PODA invalida aunque currentSeq no se mueva', () async {
    await abrirMesa('ord-1', 'mesa-1');
    await abrirMesa('ord-2', 'mesa-2');
    expect((await cache.salon(biz)).length, 2);

    final seqAntes = await log.currentSeq(biz);
    await log.retainOrders(biz, {'ord-1'});
    expect(await log.currentSeq(biz), seqAntes,
        reason: 'la marca de agua no retrocede — por eso no basta con ella');

    final salon = await cache.salon(biz);
    expect(salon.length, 1);
    expect(salon.single['table_id'], 'mesa-1');
  });

  test('un clear invalida y deja el salón vacío', () async {
    await abrirMesa('ord-1', 'mesa-1');
    expect((await cache.salon(biz)).length, 1);

    await log.clear(biz);
    expect(await cache.salon(biz), isEmpty);
  });

  test('ops() memoiza igual y comparte con salon()', () async {
    await abrirMesa('ord-1', 'mesa-1');

    await cache.ops(biz);
    final antes = counting.sinceCalls;
    await cache.salon(biz); // reusa las ops ya decodificadas
    await cache.ops(biz);

    expect(counting.sinceCalls, antes);
  });

  test('los negocios no comparten cache', () async {
    await abrirMesa('o-a', 'mesa-a', businessId: 'biz-a');
    await abrirMesa('o-b', 'mesa-b', businessId: 'biz-b');

    expect((await cache.salon('biz-a')).single['table_id'], 'mesa-a');
    expect((await cache.salon('biz-b')).single['table_id'], 'mesa-b');
  });

  test('invalidate fuerza una relectura', () async {
    await abrirMesa('ord-1', 'mesa-1');
    await cache.salon(biz);
    final antes = counting.sinceCalls;

    cache.invalidate(biz);
    await cache.salon(biz);

    expect(counting.sinceCalls, antes + 1);
  });

  test('negocio sin ops devuelve salón vacío sin romper', () async {
    expect(await cache.salon('vacio'), isEmpty);
    expect(await cache.ops('vacio'), isEmpty);
  });
}

/// Envoltorio que cuenta cuántas veces se leyó el log de verdad.
class _CountingLog implements HubOpLog {
  _CountingLog(this._inner);

  final HubOpLog _inner;
  int sinceCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> since(String businessId,
      {int seq = 0}) async {
    sinceCalls++;
    return _inner.since(businessId, seq: seq);
  }

  @override
  Future<int> currentSeq(String businessId) => _inner.currentSeq(businessId);

  @override
  Future<int> length(String businessId) => _inner.length(businessId);

  @override
  Future<int> append(String businessId, Map<String, dynamic> op) =>
      _inner.append(businessId, op);

  @override
  Future<void> clear(String businessId) => _inner.clear(businessId);

  @override
  Future<int> retainOrders(String businessId, Set<String> keepOrderIds) =>
      _inner.retainOrders(businessId, keepOrderIds);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
