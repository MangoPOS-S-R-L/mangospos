import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  for (final failure in ['timeout', '42501', 'PGRST204']) {
    test('modifier schema fallback is not a blind retry on $failure', () async {
      var requests = 0;
      final client = SupabaseClient(
        'http://localhost:54321',
        'test',
        httpClient: MockClient((request) async {
          requests++;
          if (requests == 1) {
            if (failure == 'timeout') throw TimeoutException('response lost');
            return http.Response(
              jsonEncode({'code': failure, 'message': 'probe'}),
              400,
              request: request,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('', 201, request: request);
        }),
      );
      addTearDown(client.dispose);
      final call = SalesRepository(client).addOrderItemModifiers(
        itemId: 'item',
        modifiers: [
          {
            'name': 'Extra',
            'qty': 1,
            'price': 25,
            'modifier_id': 'modifier',
            'menu_item_id': 'component',
          },
        ],
      );
      if (failure == 'PGRST204') {
        await call;
        expect(requests, 2);
      } else {
        await expectLater(call, throwsA(isA<Exception>()));
        expect(requests, 1);
      }
    });
  }
}
