import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/hub/hub_lan_scan.dart';

void main() {
  test(
    'ignores print-only agents and HTML 200; returns Windows Hub port',
    () async {
      final requests = <Uri>[];
      final scanner = HubLanScanner(
        subnetProvider: () async => ['10.101.0'],
        portProbe: (ip, port) async =>
            ['10.101.0.27', '10.101.0.93', '10.101.0.171'].contains(ip),
        httpClient: MockClient((request) async {
          requests.add(request.url);
          if (request.url.host == '10.101.0.27' && request.url.port == 4100) {
            return http.Response(
              jsonEncode({'status': 'ok', 'role': 'hub', 'business_id': 'biz'}),
              200,
            );
          }
          if (request.url.host == '10.101.0.93') {
            return http.Response('<html>Not a Hub</html>', 200);
          }
          return http.Response('{"status":"online","agent":"printer"}', 200);
        }),
      );
      addTearDown(scanner.dispose);
      final found = await scanner.scan();
      expect(found, hasLength(1));
      expect(found.single.baseUrl, 'http://10.101.0.27:4100');
      expect(requests.every((url) => url.path == '/hub/health'), isTrue);
    },
  );

  test('still finds an in-process Hub on 4000', () async {
    final scanner = HubLanScanner(
      subnetProvider: () async => ['192.168.1'],
      portProbe: (ip, port) async => ip.endsWith('.5') && port == 4000,
      httpClient: MockClient(
        (_) async => http.Response(
          '{"status":"ok","role":"hub","business_id":"biz"}',
          200,
        ),
      ),
    );
    addTearDown(scanner.dispose);
    expect((await scanner.scan()).single.port, 4000);
  });
}
