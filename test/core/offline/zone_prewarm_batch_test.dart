import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/zones_offline_cache.dart';
import 'package:mangopos/data/repositories/zones_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'prepara varias zonas con una sola lectura y conserva zonas vacías',
    () async {
      SharedPreferences.setMockInitialValues({});
      var requests = 0;
      final client = SupabaseClient(
        'http://localhost:54321',
        'test-key',
        httpClient: MockClient((request) async {
          requests++;
          expect(request.url.path, contains('dining_tables'));
          expect(
            request.url.queryParameters['zone_id'],
            contains('zone-batch-a'),
          );
          expect(
            request.url.queryParameters['zone_id'],
            contains('zone-batch-b'),
          );
          return http.Response(
            '[{"id":"table-batch-1","zone_id":"zone-batch-a","code":"A1"}]',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);

      await ZonesRepository(
        client,
      ).prewarmTablesForZones(['zone-batch-a', 'zone-batch-b']);

      expect(requests, 1);
      expect(
        (await ZonesOfflineCache().loadZoneTablesSnapshot(
          zoneId: 'zone-batch-a',
        ))?.rows.single['code'],
        'A1',
      );
      expect(
        (await ZonesOfflineCache().loadZoneTablesSnapshot(
          zoneId: 'zone-batch-b',
        ))?.rows,
        isEmpty,
      );
    },
  );

  test('pagina sin recortar mesas cuando hay más de mil', () async {
    SharedPreferences.setMockInitialValues({});
    var requests = 0;
    final firstPage = List.generate(
      1000,
      (i) => {'id': 'table-page-$i', 'zone_id': 'zone-page', 'code': '$i'},
    );
    final client = SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: MockClient((request) async {
        requests++;
        return http.Response(
          jsonEncode(
            requests == 1
                ? firstPage
                : [
                    {
                      'id': 'table-page-1000',
                      'zone_id': 'zone-page',
                      'code': '1000',
                    },
                  ],
          ),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    addTearDown(client.dispose);

    await ZonesRepository(client).prewarmTablesForZones(['zone-page']);

    expect(requests, 2);
    expect(
      (await ZonesOfflineCache().loadZoneTablesSnapshot(
        zoneId: 'zone-page',
      ))?.rows.length,
      1001,
    );
  });
}
