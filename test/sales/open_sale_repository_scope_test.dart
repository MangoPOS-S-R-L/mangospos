import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final origin in ['manual', 'quick']) {
    test(
      '$origin opens only through the atomic RPC in the active business',
      () async {
        final requests = <http.Request>[];
        final client = SupabaseClient(
          'http://localhost:54321',
          'test-key',
          httpClient: MockClient((request) async {
            requests.add(request);
            expect(request.method, 'POST');
            expect(request.url.path, '/rest/v1/rpc/fn_open_manual_or_quick');
            final params = jsonDecode(request.body) as Map<String, dynamic>;
            expect(params['p_business_id'], 'active-business');
            expect(params['p_origin'], origin);
            expect(params['p_people_count'], 3);
            return http.Response(
              jsonEncode({
                'order_id': 'opened-order',
                'session_id': 'opened-session',
                'business_id': 'active-business',
              }),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );
        addTearDown(client.dispose);

        final result = await SalesRepository(client).openManualOrQuick(
          origin: origin,
          businessId: 'active-business',
          peopleCount: 3,
        );
        expect(result['order_id'], 'opened-order');
        expect(result['business_id'], 'active-business');
        expect(requests, hasLength(1));
      },
    );
  }
}
