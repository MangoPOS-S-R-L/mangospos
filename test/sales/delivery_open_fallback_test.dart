// Crear delivery con la app publicada antes que la migración 20261009_0004:
// el servidor no tiene fn_open_delivery_order con p_business_id (PGRST202).
// La de 3 argumentos elige el negocio en el servidor: solo se usa si el
// usuario tiene un único negocio. Con varias sucursales no se crea nada (podría
// caer en otra) y se avisa. Cualquier otro error se muestra tal cual.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  http.Response json(http.Request request, Object? body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
        request: request,
      );

  http.Response postgrestError(http.Request request, String code, int status) =>
      json(request, {
        'code': code,
        'message': code == 'PGRST202'
            ? 'Could not find the function public.fn_open_delivery_order'
                  '(p_business_id, p_delivery_type, p_people_count, p_user_id) '
                  'in the schema cache'
            : 'ERROR',
        'details': null,
        'hint': null,
      }, status);

  Future<(Map<String, dynamic>?, List<Map<String, dynamic>>, Object?)> open(
    http.Response Function(http.Request request, Map<String, dynamic> params)
    server, {
    bool singleBusiness = true,
  }) async {
    final calls = <Map<String, dynamic>>[];
    final client = SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/rest/v1/rpc/fn_open_delivery_order');
        final params = jsonDecode(request.body) as Map<String, dynamic>;
        calls.add(params);
        return server(request, params);
      }),
    );
    addTearDown(client.dispose);
    try {
      final result = await SalesRepository(
        client,
      ).openDeliveryOrder(
        deliveryType: 'own',
        businessId: 'biz-activo',
        allowLegacyBusinessFallback: singleBusiness,
      );
      return (result, calls, null);
    } catch (e) {
      return (null, calls, e);
    }
  }

  test('servidor con 0004: una sola llamada, con el negocio activo', () async {
    final (result, calls, error) = await open(
      (request, params) => json(request, {'order_id': 'delivery-1'}),
    );
    expect(error, isNull);
    expect(result?['order_id'], 'delivery-1');
    expect(calls, hasLength(1));
    expect(calls.single['p_business_id'], 'biz-activo');
  });

  test(
    'servidor sin 0004 (PGRST202) y un único negocio: reintenta con la firma '
    'de 3 argumentos',
    () async {
      final (result, calls, error) = await open((request, params) {
        if (params.containsKey('p_business_id')) {
          return postgrestError(request, 'PGRST202', 404);
        }
        return json(request, {'order_id': 'delivery-legacy'});
      });
      expect(error, isNull);
      expect(result?['order_id'], 'delivery-legacy');
      expect(calls, hasLength(2));
      expect(calls.first['p_business_id'], 'biz-activo');
      expect(calls.last.containsKey('p_business_id'), isFalse);
      expect(calls.last['p_delivery_type'], 'own');
      expect(calls.last['p_people_count'], 1);
    },
  );

  test(
    'servidor sin 0004 (PGRST202) y varias sucursales: no crea nada en otra '
    'sucursal y avisa que falta actualizar el servidor',
    () async {
      final (result, calls, error) = await open((request, params) {
        if (params.containsKey('p_business_id')) {
          return postgrestError(request, 'PGRST202', 404);
        }
        return json(request, {'order_id': 'delivery-otra-sucursal'});
      }, singleBusiness: false);
      expect(result, isNull);
      expect(calls, hasLength(1), reason: 'sin la llamada de 3 argumentos');
      expect(error.toString(), contains('Falta actualizar el servidor'));
    },
  );

  test('otro error del servidor: se muestra, sin reintento', () async {
    final (result, calls, error) = await open(
      (request, params) => postgrestError(request, 'P0001', 400),
    );
    expect(result, isNull);
    expect(error, isA<PostgrestException>());
    expect(calls, hasLength(1));
  });
}
