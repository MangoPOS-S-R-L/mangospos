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
}
