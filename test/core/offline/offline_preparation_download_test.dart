import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/offline_catalog_service.dart';
import 'package:mangopos/core/offline/offline_refreshers.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'la descarga prepara también productos sin modificadores y combos',
    () async {
      SharedPreferences.setMockInitialValues({});
      const biz = 'download-fixture';
      await OfflineCatalogService().saveSnapshot(
        businessId: biz,
        products: [
          {
            'id': 'coffee',
            'name': 'Café',
            'price': 75,
            'item_type': 'standard',
          },
          {
            'id': 'combo',
            'name': 'Desayuno',
            'price': 200,
            'item_type': 'combo',
          },
        ],
      );
      final requested = <String>[];
      final client = SupabaseClient(
        'https://fixture.invalid',
        'test-key',
        httpClient: MockClient((request) async {
          final table = request.url.pathSegments.last;
          requested.add(table);
          final rows = table == 'combo_groups'
              ? [
                  {
                    'id': 'g1',
                    'name': 'Bebida',
                    'min_select': 1,
                    'max_select': 1,
                    'combo_group_items': [],
                  },
                ]
              : [];
          return http.Response(
            jsonEncode(rows),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final refreshers = buildOfflineRefreshers(
        resolveBusinessId: () => biz,
        client: client,
        refreshCatalog: (_) async {},
        refreshZones: (_) async {},
        refreshInventory: (_) async {},
        refreshConfig: (_) async {},
        refreshPrinters: (_) async {},
        refreshFiscalSequences: (_) async {},
      );
      await refreshers[6]();
      final cache = PosLookupOfflineCache();
      expect(await cache.loadBusinessTaxes(biz), isEmpty);
      expect(await cache.loadModifierGroups(biz, 'coffee'), isEmpty);
      expect(await cache.loadModifierGroups(biz, 'combo'), isEmpty);
      expect((await cache.loadComboGroups(biz, 'combo'))!.single['id'], 'g1');
      expect(requested.where((table) => table == 'combo_groups'), hasLength(1));
    },
  );
}
