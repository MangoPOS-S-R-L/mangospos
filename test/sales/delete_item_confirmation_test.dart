import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/models/order_edit.dart';
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

  // T04: borrar es una edición versionada; nunca un DELETE directo.
  test('borra por la entrada versionada con la versión que se veía', () async {
    final repo = repository((request) async {
      expect(request.url.path, endsWith('/rpc/fn_apply_order_edit'));
      return jsonResponse(request, {'status': 'applied', 'version': 5}, 200);
    });
    final edit = OrderEdit(orderId: 'order-1', base: OrderEditBase.ofVersion(4));

    await repo.deleteItem(itemId: 'item-1', edit: edit);

    expect(requests, hasLength(1));
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(body['p_op_id'], edit.opId);
    expect(body['p_kind'], 'delete');
    expect(body['p_target_id'], 'item-1');
    expect(body['p_base_version'], 4);
  });

  test('otro equipo cambió la línea: no se reporta como éxito', () async {
    final repo = repository(
      (request) async => jsonResponse(request, {
        'status': 'conflict',
        'reason': 'stale_version',
        'current_version': 6,
        'current': {'qty': 3},
      }, 200),
    );

    await expectLater(
      repo.deleteItem(
        itemId: 'item-1',
        edit: OrderEdit(orderId: 'order-1', base: OrderEditBase.ofVersion(4)),
      ),
      throwsA(
        isA<OrderEditConflict>().having(
          (conflict) => conflict.currentDescription,
          'currentDescription',
          'Ahora: cantidad 3.',
        ),
      ),
    );
    expect(requests, hasLength(1));
  });

  test('servidor sin 20261010_0006: no hay DELETE de respaldo', () async {
    final repo = repository(
      (request) async => jsonResponse(request, {
        'code': 'PGRST202',
        'message': 'Could not find the function',
      }, 404),
    );

    await expectLater(
      repo.deleteItem(
        itemId: 'item-1',
        edit: OrderEdit(orderId: 'order-1', base: OrderEditBase.ofVersion(4)),
      ),
      throwsA(isA<OrderEditServerOutdated>()),
    );
    expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
  });
}
