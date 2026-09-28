import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/data/repositories/sales_repository_improved.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  Map<String, dynamic> row({
    String code = 'cash',
    double change = 0,
    int split = 0,
  }) => {
    'id': 'payment-$split',
    'business_id': 'biz',
    'order_id': 'order',
    'check_id': null,
    'payment_method_id': 'method-uuid',
    'amount': 100,
    'change_amount': change,
    'status': 'completed',
    'split_sequence': split,
    'created_at': '2026-09-28T12:00:00Z',
    'payment_methods': {'code': code},
  };

  for (final improved in [false, true]) {
    for (final scenario in [
      'exact',
      'other method',
      'other change',
      'closed container',
    ]) {
      test(
        '${improved ? 'split' : 'base'} repository recovery: $scenario',
        () async {
          final requests = <Uri>[];
          final client = SupabaseClient(
            'http://localhost:54321',
            'test',
            httpClient: MockClient((request) async {
              requests.add(request.url);
              if (request.url.path.contains('/rpc/')) {
                if (scenario == 'closed container') {
                  return http.Response(
                    jsonEncode(row(split: 1)),
                    200,
                    request: request,
                    headers: {'content-type': 'application/json'},
                  );
                }
                return http.Response(
                  jsonEncode({
                    'code': '23505',
                    'message': 'payments_unique_completed_per_check_method',
                  }),
                  409,
                  request: request,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response(
                jsonEncode([
                  row(
                    code: scenario == 'other method' ? 'card' : 'cash',
                    change: scenario == 'other change' ? 20 : 0,
                  ),
                ]),
                200,
                request: request,
                headers: {'content-type': 'application/json'},
              );
            }),
          );
          addTearDown(client.dispose);
          final payment = improved
              ? SalesRepositoryImproved(client).processPayment(
                  orderId: 'order',
                  paymentMethodId: 'cash',
                  amount: 100,
                )
              : SalesRepository(client).processPayment(
                  orderId: 'order',
                  paymentMethodId: 'cash',
                  amount: 100,
                );
          if (scenario == 'exact' || scenario == 'closed container') {
            expect((await payment).id, 'payment-0');
          } else {
            await expectLater(payment, throwsException);
          }
          final query = requests.last.queryParameters;
          expect(query['split_sequence'], 'eq.0');
          expect(query['check_id'], 'is.null');
          expect(query['payment_methods.code'], 'eq.cash');
        },
      );
    }
  }
}
