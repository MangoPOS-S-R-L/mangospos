import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('lee varios combos en una petición y agrupa incluso los vacíos', () async {
    var requests = 0;
    final client = SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: MockClient((request) async {
        requests++;
        expect(request.url.path, contains('combo_groups'));
        expect(
          request.url.queryParameters['menu_item_id'],
          contains('combo-a'),
        );
        expect(
          request.url.queryParameters['menu_item_id'],
          contains('combo-b'),
        );
        return http.Response(
          '[{"id":"group-a","menu_item_id":"combo-a","name":"Bebida","combo_group_items":[]}]',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    addTearDown(client.dispose);

    final groups = await SalesRepository(
      client,
    ).getComboGroupsForItems(['combo-a', 'combo-b']);
    expect(requests, 1);
    expect(groups['combo-a']?.single['id'], 'group-a');
    expect(groups['combo-a']?.single.containsKey('menu_item_id'), false);
    expect(groups['combo-b'], isEmpty);
  });
}
