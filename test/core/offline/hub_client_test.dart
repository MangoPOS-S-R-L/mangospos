import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/hub/hub_client.dart';

/// Tests de HubClient (F3b-2) con http mockeado — valida el parseo de
/// postOp / getStateSince sin levantar el agente real.
void main() {
  test('postOp devuelve el seq del Hub en 200', () async {
    final mock = MockClient((req) async {
      expect(req.method, 'POST');
      expect(req.url.path, '/hub/ops');
      expect(req.headers['authorization'], contains('Bearer'));
      final body = jsonDecode(req.body) as Map;
      expect(body['business_id'], 'biz-1');
      return http.Response(jsonEncode({'seq': 7, 'op_id': 'a'}), 200);
    });
    final client = HubClient(httpClient: mock);
    final seq = await client.postOp('http://192.168.1.5:4000', {
      'op_id': 'a',
      'business_id': 'biz-1',
      'type': 'add_item',
    });
    expect(seq, 7);
  });

  test('postOp devuelve null ante error HTTP', () async {
    final mock = MockClient((req) async => http.Response('boom', 500));
    final client = HubClient(httpClient: mock);
    final seq = await client.postOp('http://h:4000', {'business_id': 'b'});
    expect(seq, isNull);
  });

  test('getStateSince parsea seq + ops', () async {
    final mock = MockClient((req) async {
      expect(req.url.queryParameters['business_id'], 'biz-1');
      expect(req.url.queryParameters['since'], '2');
      return http.Response(
        jsonEncode({
          'seq': 4,
          'ops': [
            {'seq': 3, 'op_id': 'c', 'type': 't'},
            {'seq': 4, 'op_id': 'd', 'type': 't'},
          ],
        }),
        200,
      );
    });
    final client = HubClient(httpClient: mock);
    final res = await client.getStateSince(
      'http://h:4000/',
      businessId: 'biz-1',
      since: 2,
    );
    expect(res, isNotNull);
    expect(res!.seq, 4);
    expect(res.ops.map((e) => e['op_id']), ['c', 'd']);
  });

  test('getStateSince devuelve null ante error', () async {
    final mock = MockClient((req) async => http.Response('', 404));
    final client = HubClient(httpClient: mock);
    final res =
        await client.getStateSince('http://h:4000', businessId: 'b', since: 0);
    expect(res, isNull);
  });

  // ── Réplica al respaldo (H7) ─────────────────────────────────────────────
  //
  // La primera versión usaba la dirección tal cual. El campo de Ajustes pide
  // una IP pelada, así que `Uri.parse('192.168.1.51/hub/replica')` tronaba en
  // cada op, el catch lo tragaba como "no crítico", y la replicación nunca
  // funcionó con el valor que pedía la pantalla.
  group('replicateOp', () {
    test('con una IP pelada encuentra el puerto correcto', () async {
      final vistos = <String>[];
      final mock = MockClient((req) async {
        vistos.add('${req.url.port}${req.url.path}');
        // Solo el servidor dedicado de Windows (4100) responde.
        return req.url.port == 4100 && req.url.path == '/hub/replica'
            ? http.Response(jsonEncode({'stored': true}), 200)
            : http.Response('no', 404);
      });
      final client = HubClient(httpClient: mock);

      final ok = await client.replicateOp('192.168.1.51', {
        'op_id': 'a',
        'seq': 7,
        'business_id': 'biz-1',
      });

      expect(ok, isTrue);
      expect(vistos, ['4000/hub/replica', '4100/hub/replica']);
    });

    test('manda la op con su seq intacto', () async {
      Map<String, dynamic>? recibido;
      final mock = MockClient((req) async {
        recibido = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      });
      final client = HubClient(httpClient: mock);

      await client.replicateOp('http://h:4000', {
        'op_id': 'a',
        'seq': 42,
        'business_id': 'biz-1',
      });

      expect(recibido?['seq'], 42);
      expect(recibido?['op_id'], 'a');
    });

    test('recuerda el puerto que respondió: no re-sondea en cada op', () async {
      var llamadas = 0;
      final mock = MockClient((req) async {
        llamadas++;
        return req.url.port == 4100
            ? http.Response('{}', 200)
            : http.Response('no', 404);
      });
      final client = HubClient(httpClient: mock);

      await client.replicateOp('192.168.1.51', {'op_id': 'a', 'seq': 1});
      final trasPrimera = llamadas; // 4000 falla, 4100 responde
      await client.replicateOp('192.168.1.51', {'op_id': 'b', 'seq': 2});

      expect(trasPrimera, 2);
      expect(llamadas - trasPrimera, 1, reason: 'directo al 4100 recordado');
    });

    test('si trae puerto explícito, lo prueba primero', () async {
      final vistos = <int>[];
      final mock = MockClient((req) async {
        vistos.add(req.url.port);
        return http.Response('{}', 200);
      });
      final client = HubClient(httpClient: mock);

      await client.replicateOp('http://10.0.0.9:5555', {'op_id': 'a', 'seq': 1});

      expect(vistos.first, 5555);
    });

    // La réplica es fire-and-forget. Con el respaldo apagado, sin este respiro
    // cada op del local dispararía varios sondeos que se irían apilando.
    test('respaldo caído: da false y no reintenta de inmediato', () async {
      var llamadas = 0;
      final mock = MockClient((req) async {
        llamadas++;
        return http.Response('caído', 500);
      });
      final client = HubClient(httpClient: mock);

      final primera = await client.replicateOp('192.168.1.51', {'seq': 1});
      final trasPrimera = llamadas;
      final segunda = await client.replicateOp('192.168.1.51', {'seq': 2});

      expect(primera, isFalse);
      expect(segunda, isFalse);
      expect(trasPrimera, 2, reason: 'se probaron 4000 y 4100');
      expect(llamadas, trasPrimera, reason: 'dentro del respiro no se sondea');
    });

    test('dirección vacía no hace nada', () async {
      var llamadas = 0;
      final mock = MockClient((req) async {
        llamadas++;
        return http.Response('{}', 200);
      });
      final client = HubClient(httpClient: mock);

      expect(await client.replicateOp('   ', {'seq': 1}), isFalse);
      expect(llamadas, 0);
    });
  });

  // ── Ack de lo subido (H7) ────────────────────────────────────────────────
  //
  // Sin el ack, al promover el respaldo subiría también lo que el Hub ya había
  // subido antes de morir, y como la BD no tiene llave de idempotencia sería
  // venta doble.
  group('ackReplica', () {
    test('manda a /hub/replica/ack los op_id subidos, resolviendo el puerto',
        () async {
      Map<String, dynamic>? recibido;
      final vistos = <String>[];
      final mock = MockClient((req) async {
        vistos.add('${req.url.port}${req.url.path}');
        if (req.url.port != 4100) return http.Response('no', 404);
        recibido = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      });
      final client = HubClient(httpClient: mock);

      final ok = await client.ackReplica(
        '192.168.1.51',
        businessId: 'biz-1',
        completedOpIds: ['op-1', 'op-2'],
      );

      expect(ok, isTrue);
      expect(vistos.last, '4100/hub/replica/ack');
      expect(recibido?['business_id'], 'biz-1');
      expect(recibido?['completed_op_ids'], ['op-1', 'op-2']);
    });

    test('sin poda no manda keep_order_ids', () async {
      Map<String, dynamic>? recibido;
      final mock = MockClient((req) async {
        recibido = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      });
      final client = HubClient(httpClient: mock);

      await client.ackReplica(
        'http://h:4000',
        businessId: 'biz-1',
        completedOpIds: ['op-1'],
      );

      expect(recibido?.containsKey('keep_order_ids'), isFalse);
      expect(recibido?.containsKey('up_to_seq'), isFalse);
    });

    test('con poda manda las órdenes a conservar y el tope de seq', () async {
      Map<String, dynamic>? recibido;
      final mock = MockClient((req) async {
        recibido = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      });
      final client = HubClient(httpClient: mock);

      await client.ackReplica(
        'http://h:4000',
        businessId: 'biz-1',
        completedOpIds: ['op-1'],
        keepOrderIds: {'orden-viva'},
        upToSeq: 42,
      );

      expect(recibido?['keep_order_ids'], ['orden-viva']);
      expect(recibido?['up_to_seq'], 42);
    });

    // Réplica y ack comparten el puerto recordado: tras encontrar el 4100 con
    // una réplica, el ack va directo sin volver a sondear.
    test('reusa el puerto que encontró la réplica', () async {
      var llamadas = 0;
      final mock = MockClient((req) async {
        llamadas++;
        return req.url.port == 4100
            ? http.Response('{}', 200)
            : http.Response('no', 404);
      });
      final client = HubClient(httpClient: mock);

      await client.replicateOp('192.168.1.51', {'op_id': 'a', 'seq': 1});
      final trasReplica = llamadas;
      await client.ackReplica(
        '192.168.1.51',
        businessId: 'biz-1',
        completedOpIds: ['a'],
      );

      expect(llamadas - trasReplica, 1);
    });
  });
}
