import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_op_log.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests del op-log del Hub (F3b-1): seq monotónico, append idempotente y
/// delta `since`. Usa el mock de SharedPreferences (StorageService lo envuelve).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HubOpLog log;
  const biz = 'biz-1';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.getInstance();
    // Limpia el op-log entre tests (StorageService es singleton).
    await storage.write(debugHubOpLogKey(biz), '[]');
    log = HubOpLog(storage: storage);
  });

  test('append asigna seq monotónico creciente', () async {
    final s1 = await log.append(biz, {'op_id': 'a', 'type': 'add_item'});
    final s2 = await log.append(biz, {'op_id': 'b', 'type': 'add_item'});
    final s3 = await log.append(biz, {'op_id': 'c', 'type': 'delete_item'});
    expect(s1, 1);
    expect(s2, 2);
    expect(s3, 3);
    expect(await log.currentSeq(biz), 3);
    expect(await log.length(biz), 3);
  });

  test('append es idempotente por op_id (no duplica, devuelve seq previo)',
      () async {
    final first = await log.append(biz, {'op_id': 'x', 'type': 'add_item'});
    final again = await log.append(biz, {'op_id': 'x', 'type': 'add_item'});
    expect(first, again);
    expect(await log.length(biz), 1);
  });

  test('since(seq) devuelve solo el delta en orden', () async {
    await log.append(biz, {'op_id': 'a', 'type': 't'});
    await log.append(biz, {'op_id': 'b', 'type': 't'});
    await log.append(biz, {'op_id': 'c', 'type': 't'});

    final delta = await log.since(biz, seq: 1);
    expect(delta.map((e) => e['op_id']), ['b', 'c']);
    expect(delta.map((e) => e['seq']), [2, 3]);

    final all = await log.since(biz);
    expect(all.length, 3);
  });

  test('append estampa hub_received_at y conserva el payload', () async {
    await log.append(biz, {'op_id': 'a', 'type': 'add_item', 'qty': 5});
    final all = await log.since(biz);
    expect(all.single['qty'], 5);
    expect(all.single['hub_received_at'], isNotNull);
  });

  test('clear vacía el log', () async {
    await log.append(biz, {'op_id': 'a', 'type': 't'});
    await log.clear(biz);
    expect(await log.length(biz), 0);
    expect(await log.currentSeq(biz), 0);
    // Tras limpiar, el seq reinicia en 1 (nueva ventana offline).
    expect(await log.append(biz, {'op_id': 'z', 'type': 't'}), 1);
  });

  test('op-logs de negocios distintos no se mezclan', () async {
    await log.append('biz-A', {'op_id': 'a', 'type': 't'});
    await log.append('biz-B', {'op_id': 'b', 'type': 't'});
    expect(await log.length('biz-A'), 1);
    expect(await log.length('biz-B'), 1);
  });

  // Fix #2: la poda del uplink conserva las mesas abiertas y descarta el resto.
  group('retainOrders (poda que conserva mesas abiertas)', () {
    test('conserva solo las ops de las órdenes indicadas; poda el resto '
        '(incl. ops sin order_id)', () async {
      await log.append(biz, {'op_id': '1', 'type': 'open_table', 'order_id': 'o1'});
      await log.append(biz, {'op_id': '2', 'type': 'add_item', 'order_id': 'o1'});
      await log.append(biz, {'op_id': '3', 'type': 'open_table', 'order_id': 'o2'});
      await log.append(biz, {'op_id': '4', 'type': 'add_item', 'order_id': 'o2'});
      await log.append(biz, {'op_id': '5', 'type': 'cash_transaction'}); // sin order_id

      final remaining = await log.retainOrders(biz, {'o1'});

      expect(remaining, 2);
      final all = await log.since(biz);
      expect(all.map((e) => e['order_id']), ['o1', 'o1']);
      expect(all.any((e) => e['order_id'] == 'o2'), false);
      expect(all.any((e) => e['type'] == 'cash_transaction'), false);
    });

    test('set vacío deja el log vacío', () async {
      await log.append(biz, {'op_id': '1', 'type': 'open_table', 'order_id': 'o1'});
      expect(await log.retainOrders(biz, <String>{}), 0);
      expect(await log.length(biz), 0);
    });

    test('no toca el log si todas las órdenes se conservan', () async {
      await log.append(biz, {'op_id': '1', 'type': 'open_table', 'order_id': 'o1'});
      await log.append(biz, {'op_id': '2', 'type': 'add_item', 'order_id': 'o1'});
      expect(await log.retainOrders(biz, {'o1', 'o2'}), 2);
      expect(await log.length(biz), 2);
    });
  });
}
