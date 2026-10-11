// «Enviar Pedido» confirma a cocina SOLO la ronda capturada
// (fn_confirm_order_items_to_kitchen, 20261010_0002) y conserva la fusión con
// la comanda anterior del KDS. Sin la migración en el servidor falla con un
// error visible antes de imprimir: nunca amplía la confirmación a la orden
// entera (marcaría enviados productos que no salen en el papel).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _order = '0e000000-0000-4000-8000-000000000001';
const _a = '4e000000-0000-4000-8000-000000000001';
const _b = '4e000000-0000-4000-8000-000000000002';

class _Sales extends SalesRepository {
  _Sales(super.client, {this.roundError});
  final Object? roundError;
  final rounds = <String>[];
  final wholeOrders = <String>[];

  @override
  Future<({bool merged, DateTime roundStamp})> confirmRoundToKitchen(
    String orderId,
    List<String> itemIds,
  ) async {
    final error = roundError;
    if (error != null) throw error;
    rounds.add('$orderId:${itemIds.join(',')}');
    return (merged: true, roundStamp: DateTime.utc(2026, 10, 10, 21, 51));
  }

  @override
  Future<({bool merged, DateTime roundStamp})> sendToKitchen(
    String orderId, {
    bool allowMerge = true,
  }) async {
    wholeOrders.add(orderId);
    return (merged: false, roundStamp: DateTime.utc(2026, 10, 10));
  }
}

void main() {
  final client = SupabaseClient('http://localhost:54321', 'test-key');
  tearDownAll(client.dispose);

  test('confirma solo las líneas de la ronda y conserva la fusión', () async {
    final sales = _Sales(client);
    final printing = PrintingService(client, salesRepository: sales);
    final result = await printing.confirmCapturedRound(_order, [_a, _b]);
    expect(sales.rounds, ['$_order:$_a,$_b']);
    expect(sales.wholeOrders, isEmpty);
    expect(result.merged, isTrue, reason: '«AGREGADO A COMANDA» sigue igual');
  });

  test('[P2] sin la migración 0002 NO amplía la confirmación: error visible '
      'y nada confirmado', () async {
    final sales = _Sales(
      client,
      roundError: const PostgrestException(
        message:
            'Could not find the function '
            'public.fn_confirm_order_items_to_kitchen in the schema cache',
        code: 'PGRST202',
      ),
    );
    final printing = PrintingService(client, salesRepository: sales);
    await expectLater(
      printing.confirmCapturedRound(_order, [_a]),
      throwsA(
        isA<KitchenRoundRpcMissingException>().having(
          (e) => e.toString(),
          'mensaje',
          contains('20261010_0002'),
        ),
      ),
    );
    expect(sales.wholeOrders, isEmpty, reason: 'nunca la orden entera');
    expect(sales.rounds, isEmpty);
  });

  test('otro error no cae a la orden entera: se propaga', () async {
    final sales = _Sales(client, roundError: http.ClientException('reset'));
    final printing = PrintingService(client, salesRepository: sales);
    await expectLater(
      printing.confirmCapturedRound(_order, [_a]),
      throwsA(isA<http.ClientException>()),
    );
    expect(sales.wholeOrders, isEmpty);
  });

  test('SalesRepository.confirmRoundToKitchen: RPC con los ids y sello de '
      'ronda solo en esas líneas', () async {
    final requests = <http.Request>[];
    final mock = SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        final body = request.method == 'GET' ? '[]' : 'null';
        return http.Response(
          body,
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    addTearDown(mock.dispose);
    final result = await SalesRepository(
      mock,
    ).confirmRoundToKitchen(_order, [_a, _b]);
    expect(result.merged, isFalse, reason: 'sin ronda anterior');

    final rpc = requests.firstWhere(
      (r) => r.url.path.endsWith('/rpc/fn_confirm_order_items_to_kitchen'),
    );
    expect(jsonDecode(rpc.body), {
      'p_order_id': _order,
      'p_item_ids': [_a, _b],
    });
    final stamp = requests.firstWhere(
      (r) => r.method == 'PATCH' && r.url.path.endsWith('/order_items'),
    );
    final query = Uri.decodeComponent(stamp.url.query);
    expect(query, contains('id=in.("$_a","$_b")'));
    expect(query, contains('kitchen_sent_at=is.null'));
    expect(query, contains('order_id=eq.$_order'));
  });
}
