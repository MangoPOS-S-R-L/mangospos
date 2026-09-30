import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mangopos/core/agent/mobile_print_agent.dart';
import 'package:mangopos/core/auth/offline_auth_service.dart';
import 'package:mangopos/core/offline/hub/hub_client.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_lan_token.dart';
import 'package:mangopos/core/offline/hub/hub_roster_codec.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Auth implements OfflineAuthService {
  bool stale = false;
  final timestamp = DateTime.now().toUtc().toIso8601String();
  @override
  Future<bool> isRosterStale(String businessId) async => stale;
  @override
  Future<Map<String, dynamic>?> cachedRosterPayload(String businessId) async =>
      {
        'business_id': businessId,
        'synced_at': timestamp,
        'roster': [
          {'user_id': 'u', 'pin_hash': 'private-hash'},
        ],
      };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const token = 'private-business-secret';
  late StorageService storage;
  late MobilePrintAgent agent;
  late HubClient client;
  late _Auth auth;
  var cloudAvailable = true;
  const url = 'http://127.0.0.1:47312';

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.getInstance();
    auth = _Auth();
    agent = MobilePrintAgent(
      hubTokens: HubLanTokenService(readToken: (_) async => token),
      offlineAuth: auth,
      cloudAvailable: () => cloudAvailable,
    );
    expect(await agent.start(port: 47312), isNotNull);
    client = HubClient(businessToken: (_) async => token);
  });
  setUp(() async {
    await storage.clear();
    await storage.write(StorageKeys.activeBusinessId, 'b');
    await HubConfigService().setDeviceRole('b', HubDeviceRole.hub);
    auth.stale = false;
    cloudAvailable = true;
  });
  tearDownAll(() async {
    client.dispose();
    await agent.stop();
  });

  test(
    'known WAN outage rejects cloud proxies without a cloud dependency',
    () async {
      cloudAvailable = false;
      for (final path in ['open-table', 'add-item']) {
        final response = await http.post(
          Uri.parse('$url/hub/proxy/$path'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'table_id': 't',
            'order_id': 'o',
            'menu_item_id': 'p',
          }),
        );
        expect(response.statusCode, 503);
        expect(response.body, contains('HUB_WAN_OFFLINE'));
      }
      // Local discovery and cached data remain available despite WAN failure.
      expect(
        await client.findReachableHub(businessId: 'b', configuredUrl: url),
        url,
      );
      expect(await client.getRoster(url, businessId: 'b'), isNotNull);
    },
  );

  test(
    'client downloads PINs from the real local server without cloud calls',
    () async {
      final roster = await client.getRoster(url, businessId: 'b');
      expect(roster?['synced_at'], auth.timestamp);
      expect((roster?['roster'] as List).single['pin_hash'], 'private-hash');
      expect(
        await client.findReachableHub(businessId: 'b', configuredUrl: url),
        url,
      );
    },
  );

  test(
    'legacy credential and anonymous requests cannot access the roster',
    () async {
      for (final headers in [
        <String, String>{},
        {'Authorization': 'Bearer $kLegacyHubLanToken'},
      ]) {
        final response = await http.get(
          Uri.parse('$url/hub/roster?business_id=b'),
          headers: headers,
        );
        expect(response.statusCode, 403);
        expect(response.body, isNot(contains('private-hash')));
      }
    },
  );

  test('signed request cannot read another business', () async {
    final headers = await HubRosterCodec.requestHeaders(
      businessId: 'b',
      token: token,
    );
    final response = await http.get(
      Uri.parse('$url/hub/roster?business_id=other'),
      headers: headers,
    );
    expect(response.statusCode, 403);
    expect(await client.getRoster(url, businessId: 'other'), isNull);
  });

  test('expired permissions are not exported as a fresh LAN copy', () async {
    auth.stale = true;
    expect(await client.getRoster(url, businessId: 'b'), isNull);
  });

  test('a waiter terminal does not impersonate the hub', () async {
    await HubConfigService().setDeviceRole('b', HubDeviceRole.pos);
    expect(await client.getRoster(url, businessId: 'b'), isNull);
  });

  test('business changes immediately change endpoint scope', () async {
    expect(await client.getRoster(url, businessId: 'b'), isNotNull);
    await storage.write(StorageKeys.activeBusinessId, 'other');
    expect(await client.getRoster(url, businessId: 'b'), isNull);
    final health = await http.get(Uri.parse('$url/hub/health'));
    expect(jsonDecode(health.body)['business_id'], 'other');
  });

  test(
    'reference data is served without including transaction queues',
    () async {
      await storage.write('offline_catalog_b', '{"products":[]}');
      await storage.write('offline_queue_b', '["pending"]');
      final snapshot = await client.getReadCache(url, businessId: 'b');
      expect(snapshot?['entries'], {'offline_catalog_b': '{"products":[]}'});
    },
  );
}
