// Sello de quién autorizó con PIN de supervisor un producto quitado de la
// cuenta (fn_approve_order_item_removal, 20261005_0003). Lo importante: manda
// el PIN al servidor para que lo valide allá, y nunca tumba el retiro.

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

  test('manda el ítem y el PIN, y devuelve el nombre del aprobador', () async {
    final repo = repository(
      (request) async => jsonResponse(request, {
        'approved': true,
        'approver_name': 'Ana Gerente',
      }, 200),
    );

    final result = await repo.approveItemRemoval(
      itemId: 'item-1',
      approverPin: '2222',
    );

    expect(result.approved, isTrue);
    expect(result.approverName, 'Ana Gerente');
    expect(
      requests.single.url.path,
      endsWith('/rpc/fn_approve_order_item_removal'),
    );
    expect(jsonDecode(requests.single.body), {
      'p_item_id': 'item-1',
      'p_approver_pin': '2222',
    });
  });

  test('PIN rechazado por el servidor: no se sella', () async {
    final repo = repository(
      (request) async => jsonResponse(request, {
        'approved': false,
        'error_code': 'APPROVAL_DENIED',
      }, 200),
    );

    final result = await repo.approveItemRemoval(
      itemId: 'item-1',
      approverPin: '9999',
    );
    expect(result.approved, isFalse);
    expect(result.approverName, isNull);
  });

  test('sin la migración (o sin red) no lanza', () async {
    final repo = repository(
      (request) async => jsonResponse(request, {
        'code': 'PGRST202',
        'message': 'Could not find the function',
      }, 404),
    );

    final result = await repo.approveItemRemoval(
      itemId: 'item-1',
      approverPin: '2222',
    );
    expect(result.approved, isFalse);
  });
}
