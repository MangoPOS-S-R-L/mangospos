import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late List<http.Request> requests;

  SalesRepository repository(
    Future<http.Response> Function(http.Request) handler,
  ) => SalesRepository(
    SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: MockClient((request) {
        requests.add(request);
        return handler(request);
      }),
    ),
  );

  http.Response jsonResponse(http.Request request, Object body, int status) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
        request: request,
      );

  setUp(() => requests = []);

  test('DELETE confirmado elimina exactamente el item solicitado', () async {
    final repo = repository((request) async {
      expect(request.method, 'DELETE');
      expect(request.url.queryParameters['id'], 'eq.item-1');
      return jsonResponse(request, [
        {'id': 'item-1'},
      ], 200);
    });

    await repo.deleteItem(itemId: 'item-1');
    expect(requests, hasLength(1));
    expect(requests.single.url.queryParameters['select'], 'id');
  });

  test('DELETE sin filas no se reporta como éxito', () async {
    final repo = repository((request) async {
      if (request.method == 'DELETE') {
        return jsonResponse(request, [], 200);
      }
      expect(request.url.path, endsWith('/rpc/fn_delete_item'));
      return jsonResponse(request, {
        'code': 'P0001',
        'message': 'ITEM_NOT_FOUND',
      }, 400);
    });

    await expectLater(
      repo.deleteItem(itemId: 'item-1'),
      throwsA(isA<Exception>()),
    );
    expect(requests, hasLength(2));
  });
}
