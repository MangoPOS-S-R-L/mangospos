import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/hub/hub_client.dart';
import 'package:mangopos/core/printing/agent_discovery.dart';

class _NoMdns extends AgentDiscovery {
  @override
  Future<List<DiscoveredAgent>> discover({
    Duration timeout = const Duration(seconds: 4),
    String? businessIdFilter,
  }) async => [];
}

void main() {
  test(
    'finds a Windows Hub without IP or mDNS and excludes another business',
    () async {
      final client = HubClient(
        discovery: _NoMdns(),
        lanScan: () async => [
          const DiscoveredAgent(name: 'other', host: '192.168.1.2', port: 4000),
          const DiscoveredAgent(
            name: 'cashier',
            host: '192.168.1.3',
            port: 4000,
          ),
        ],
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'role': request.url.port == 4100 ? 'hub' : 'pos',
              'business_id': request.url.host.endsWith('.3') ? 'biz' : 'other',
            }),
            200,
          ),
        ),
      );
      addTearDown(client.dispose);
      expect(
        await client.findReachableHub(businessId: 'biz', scanFallback: true),
        'http://192.168.1.3:4100',
      );
    },
  );

  test(
    'does not scan every five seconds or scan without a business scope',
    () async {
      var scans = 0;
      final client = HubClient(
        discovery: _NoMdns(),
        lanScan: () async {
          scans++;
          return [];
        },
      );
      addTearDown(client.dispose);
      await client.findReachableHub(businessId: 'biz', scanFallback: true);
      await client.findReachableHub(businessId: 'biz', scanFallback: true);
      await client.findReachableHub(scanFallback: true);
      expect(scans, 1);
    },
  );

  test(
    'a remembered Hub is probed directly without a new subnet scan',
    () async {
      var scans = 0;
      final client = HubClient(
        discovery: _NoMdns(),
        lanScan: () async {
          scans++;
          return [];
        },
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'role': 'hub', 'business_id': 'biz'}),
            200,
          ),
        ),
      );
      addTearDown(client.dispose);
      expect(
        await client.findReachableHub(
          businessId: 'biz',
          configuredUrl: 'http://192.168.1.3:4100',
          scanFallback: true,
        ),
        isNotNull,
      );
      expect(scans, 0);
    },
  );
}
