import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Dueño de la mesa para sellar el autor de un ítem sin PIN. En producción
/// `fn_order_opener_employee_id` no existe: el repositorio lee el mesero del
/// PIN de la sesión (como la impresión) para que siga por delante del usuario
/// conectado, y no vuelve a pagar la RPC perdida en cada alta.
void main() {
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  // postgrest lee `response.request`: cada respuesta simulada lo lleva.
  http.Request? current;

  SalesRepository repo() => SalesRepository(
    SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: MockClient((request) {
        requests.add(request);
        current = request;
        return handler(request);
      }),
    ),
  );

  http.Response json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
    request: current,
  );

  http.Response missingRpc() => json({
    'code': 'PGRST202',
    'message': 'Could not find the function public.fn_order_opener_employee_id',
    'details': null,
    'hint': null,
  }, 404);

  int callsTo(String path) =>
      requests.where((r) => r.url.path.endsWith(path)).length;

  setUp(() {
    requests = [];
    SalesRepository.debugResetOpenerRpcProbe();
  });

  test('RPC inexistente (PGRST202): lee el mesero del PIN de la sesión y no '
      'vuelve a probar la RPC en cada alta', () async {
    handler = (request) async {
      if (request.url.path.endsWith('/fn_order_opener_employee_id')) {
        return missingRpc();
      }
      expect(request.url.path, endsWith('/orders'));
      expect(request.url.queryParameters['id'], 'eq.order-1');
      return json({
        'id': 'order-1',
        'table_sessions': {'opened_by_employee_id': 'emp-pin-opener'},
      });
    };
    final repository = repo();

    expect(await repository.fetchOrderOpenerEmployeeId('order-1'),
        'emp-pin-opener');
    expect(await repository.fetchOrderOpenerEmployeeId('order-1'),
        'emp-pin-opener');

    expect(
      callsTo('/fn_order_opener_employee_id'),
      1,
      reason: 'la función ausente no se vuelve a probar en cada alta',
    );
    expect(callsTo('/orders'), 2);
  });

  test('RPC inexistente y mesa abierta sin PIN: null (el llamador sigue al '
      'empleado del usuario conectado)', () async {
    handler = (request) async {
      if (request.url.path.endsWith('/fn_order_opener_employee_id')) {
        return missingRpc();
      }
      return json({
        'id': 'order-2',
        'table_sessions': {'opened_by_employee_id': null},
      });
    };

    expect(await repo().fetchOrderOpenerEmployeeId('order-2'), isNull);
  });

  test('cuerpo del repo sin el alias (42703): también lee la sesión', () async {
    handler = (request) async {
      if (request.url.path.endsWith('/fn_order_opener_employee_id')) {
        return json({
          'code': '42703',
          'message': 'column c.business_id does not exist',
          'details': null,
          'hint': null,
        }, 400);
      }
      return json({
        'id': 'order-3',
        'table_sessions': {'opened_by_employee_id': 'emp-pin-3'},
      });
    };

    expect(await repo().fetchOrderOpenerEmployeeId('order-3'), 'emp-pin-3');
  });

  test('la RPC existe: su respuesta manda y no se lee la sesión', () async {
    handler = (_) async => json('emp-rpc');

    expect(await repo().fetchOrderOpenerEmployeeId('order-4'), 'emp-rpc');
    expect(callsTo('/orders'), 0);
  });

  test('otro error de la RPC se propaga sin leer la sesión', () async {
    handler = (_) async => throw TimeoutException('no WAN');

    await expectLater(
      repo().fetchOrderOpenerEmployeeId('order-5'),
      throwsA(anything),
    );
    expect(callsTo('/orders'), 0);
  });

  test('RPC inexistente y orden no visible: error, no «sin dueño»', () async {
    handler = (request) async {
      if (request.url.path.endsWith('/fn_order_opener_employee_id')) {
        return missingRpc();
      }
      return json([]); // RLS u orden inexistente: cero filas
    };

    await expectLater(
      repo().fetchOrderOpenerEmployeeId('order-6'),
      throwsA(isA<StateError>()),
    );
  });
}
