import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Alta de ítem idempotente (20260929_0001): el repositorio manda el
/// client_op_id y SOLO cae a la RPC vieja cuando la función no existe.
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

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
    request: current,
  );

  int callsTo(String path) =>
      requests.where((r) => r.url.path.endsWith(path)).length;

  setUp(() {
    requests = [];
    SalesRepository.debugResetIdempotentAddProbe();
  });

  test('manda el client_op_id y devuelve el ítem del servidor', () async {
    handler = (_) async =>
        json({'item_id': 'item-1', 'replayed': false, 'item_exists': true});

    final added = await repo().addItemFromMenuIdempotent(
      clientOpId: 'op-1',
      orderId: 'order-1',
      menuItemId: 'menu-1',
      quantity: 2,
      createdByEmployeeId: 'emp-1',
    );

    expect(added.itemId, 'item-1');
    expect(added.replayed, isFalse);
    expect(added.itemExists, isTrue);
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(
      requests.single.url.path,
      endsWith('/fn_add_item_from_menu_idempotent'),
    );
    expect(body['p_client_op_id'], 'op-1');
    expect(body['p_order_id'], 'order-1');
    expect(body['p_qty'], 2);
    expect(body['p_created_by_employee_id'], 'emp-1');
  });

  test('reintento: el servidor devuelve el mismo ítem (replayed)', () async {
    handler = (_) async =>
        json({'item_id': 'item-1', 'replayed': true, 'item_exists': false});

    final added = await repo().addItemFromMenuIdempotent(
      clientOpId: 'op-1',
      orderId: 'order-1',
      menuItemId: 'menu-1',
    );

    expect(added.itemId, 'item-1');
    expect(added.replayed, isTrue);
    expect(added.itemExists, isFalse);
  });

  test('migración sin aplicar (PGRST202): bloquea el alta insegura', () async {
    handler = (request) async {
      if (request.url.path.endsWith('/fn_add_item_from_menu_idempotent')) {
        return json({
          'code': 'PGRST202',
          'message': 'Could not find the function',
          'details': null,
          'hint': null,
        }, 404);
      }
      if (request.url.path.endsWith('/fn_add_item_from_menu')) {
        return json('legacy-item');
      }
      return json([]); // PATCH del autor
    };
    final repository = repo();

    await expectLater(
      repository.addItemFromMenuIdempotent(
        clientOpId: 'op-1',
        orderId: 'order-1',
        menuItemId: 'menu-1',
        createdByEmployeeId: 'emp-1',
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      repository.addItemFromMenuIdempotent(
        clientOpId: 'op-2',
        orderId: 'order-1',
        menuItemId: 'menu-1',
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      callsTo('/fn_add_item_from_menu_idempotent'),
      1,
      reason: 'la función ausente no se vuelve a probar en cada alta',
    );
    expect(callsTo('/fn_add_item_from_menu'), 0);
  });

  test('error de negocio: se propaga y NO cae a la RPC vieja', () async {
    handler = (_) async => json({
      'code': 'P0001',
      'message': 'MENU_ITEM_NOT_FOUND',
      'details': null,
      'hint': null,
    }, 400);

    await expectLater(
      repo().addItemFromMenuIdempotent(
        clientOpId: 'op-1',
        orderId: 'order-1',
        menuItemId: 'menu-1',
      ),
      throwsA(isA<Exception>()),
    );
    expect(callsTo('/fn_add_item_from_menu'), 0);
  });

  test(
    'respuesta perdida: error de red, sin segunda alta; la app lo encola',
    () async {
      handler = (_) async => throw TimeoutException('ack perdido');

      Object? error;
      try {
        await repo().addItemFromMenuIdempotent(
          clientOpId: 'op-1',
          orderId: 'order-1',
          menuItemId: 'menu-1',
        );
      } catch (e) {
        error = e;
      }

      expect(error, isNotNull);
      // El viewmodel decide encolar (con el MISMO id) por esta clasificación.
      expect(OfflinePosService.isTransportError(error!), isTrue);
      expect(callsTo('/fn_add_item_from_menu'), 0);
      expect(callsTo('/fn_add_item_from_menu_idempotent'), 1);
    },
  );

  test('orden cobrada (MP401): mensaje amigable, sin RPC vieja', () async {
    handler = (_) async => json({
      'code': 'MP401',
      'message': 'MP401: cuenta ya cobrada',
      'details': null,
      'hint': null,
    }, 400);

    Object? error;
    try {
      await repo().addItemFromMenuIdempotent(
        clientOpId: 'op-1',
        orderId: 'order-1',
        menuItemId: 'menu-1',
      );
    } catch (e) {
      error = e;
    }
    expect(error.toString(), isNot(contains('PostgrestException')));
    expect(callsTo('/fn_add_item_from_menu'), 0);
  });

  group('oferta (tile deal)', () {
    Future<void> addDeal(SalesRepository repository) =>
        repository.addOfferDealItem(
          orderId: 'order-1',
          menuItemId: 'menu-1',
          quantity: 4,
          discount: 250,
          name: '4x3 Presidente',
          promotionId: 'promo-1',
          clientOpId: 'deal-op',
        );

    http.Response postgrestError(String code, int status) => json({
      'code': code,
      'message': code,
      'details': null,
      'hint': null,
    }, status);

    test('manda el client_op_id a la RPC idempotente', () async {
      handler = (_) async => json({
        'item_id': 'deal-item',
        'replayed': false,
        'item_exists': true,
      });

      await addDeal(repo());

      expect(requests, hasLength(1));
      expect(
        requests.single.url.path,
        endsWith('/fn_add_offer_deal_idempotent'),
      );
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body['p_client_op_id'], 'deal-op');
      expect(body['p_discount'], 250);
    });

    test(
      'la oferta viva falla en el servidor: alta normal con el MISMO id',
      () async {
        handler = (request) async {
          final path = request.url.path;
          if (path.endsWith('/fn_add_offer_deal_idempotent')) {
            return postgrestError('42725', 400);
          }
          if (path.endsWith('/fn_add_item_from_menu_idempotent')) {
            return json({
              'item_id': 'deal-item',
              'replayed': false,
              'item_exists': true,
            });
          }
          return json([]); // PATCH nombre/descuento/marcador
        };

        await addDeal(repo());

        final add = requests.singleWhere(
          (r) => r.url.path.endsWith('/fn_add_item_from_menu_idempotent'),
        );
        expect(
          (jsonDecode(add.body) as Map<String, dynamic>)['p_client_op_id'],
          'deal-op',
        );
        final patch = requests.singleWhere((r) => r.method == 'PATCH');
        final payload = jsonDecode(patch.body) as Map<String, dynamic>;
        expect(payload['discounts'], 250);
        expect(payload['notes'], '[DEAL:promo-1]');
      },
    );

    test('error de red: se propaga, sin segunda alta de ningún tipo', () async {
      handler = (_) async => throw TimeoutException('ack perdido');

      await expectLater(addDeal(repo()), throwsA(anything));

      expect(requests, hasLength(1));
      expect(callsTo('/fn_add_offer_deal'), 0);
      expect(callsTo('/fn_add_item_from_menu_idempotent'), 0);
      expect(callsTo('/fn_add_item_from_menu'), 0);
    });

    test('migración sin aplicar: oferta tampoco usa la RPC vieja', () async {
      handler = (request) async {
        if (request.url.path.endsWith('/fn_add_offer_deal_idempotent')) {
          return postgrestError('PGRST202', 404);
        }
        throw TimeoutException('ack perdido');
      };

      await expectLater(addDeal(repo()), throwsA(anything));

      expect(callsTo('/fn_add_offer_deal'), 0);
      expect(callsTo('/fn_add_item_from_menu_idempotent'), 0);
      expect(callsTo('/fn_add_item_from_menu'), 0);
    });

    test(
      'orden cobrada (MP401): mensaje amigable, sin alta de respaldo',
      () async {
        handler = (_) async => postgrestError('MP401', 400);

        Object? error;
        try {
          await addDeal(repo());
        } catch (e) {
          error = e;
        }

        expect(error.toString(), isNot(contains('PostgrestException')));
        expect(requests, hasLength(1));
      },
    );
  });

  group('reemplazo de modificadores', () {
    const modifiers = [
      {'name': 'Queso', 'qty': 1, 'price': 50},
    ];

    test('una sola RPC atómica, sin DELETE suelto', () async {
      handler = (_) async => json(1);

      await repo().replaceOrderItemModifiers(
        itemId: 'item-1',
        modifiers: modifiers,
      );

      expect(requests, hasLength(1));
      expect(
        requests.single.url.path,
        endsWith('/fn_replace_order_item_modifiers'),
      );
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body['p_item_id'], 'item-1');
      expect(body['p_modifiers'], modifiers);
    });

    test('migración sin aplicar: cae al DELETE + INSERT de antes', () async {
      handler = (request) async {
        if (request.url.path.endsWith('/fn_replace_order_item_modifiers')) {
          return json({
            'code': 'PGRST202',
            'message': 'Could not find the function',
            'details': null,
            'hint': null,
          }, 404);
        }
        return json([]);
      };

      await repo().replaceOrderItemModifiers(
        itemId: 'item-1',
        modifiers: modifiers,
      );

      expect(
        requests.where((r) => r.method == 'DELETE').map((r) => r.url.path),
        [endsWith('/order_item_modifiers')],
      );
      expect(
        requests.where((r) => r.method == 'POST').map((r) => r.url.path).last,
        endsWith('/order_item_modifiers'),
      );
    });

    test('error de red: no borra nada por fuera de la RPC', () async {
      handler = (_) async => throw TimeoutException('ack perdido');

      await expectLater(
        repo().replaceOrderItemModifiers(
          itemId: 'item-1',
          modifiers: modifiers,
        ),
        throwsA(isA<Exception>()),
      );

      expect(requests, hasLength(1));
      expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
    });
  });
}
