import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mangopos/core/services/local_print_service.dart';
import 'package:mangopos/core/printing/print_delivery_exception.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocalPrintService.primeBaseUrl('http://127.0.0.1:4000');
  });

  test('USB job accepts durable 202 without a second submission', () async {
    var submissions = 0;
    await http.runWithClient(
      () async {
        await LocalPrintService(apiToken: 'test').printRawToAssignedPrinter(
          printer: {'id': 'usb-id', 'type': 'usb', 'device_path': 'POS80'},
          data: [27, 64],
          jobId: 'ticket-stable-id',
        );
      },
      () => MockClient((request) async {
        submissions++;
        final body = jsonDecode(request.body) as Map;
        expect(body['id'], 'ticket-stable-id');
        expect(body['printer']['device_path'], 'POS80');
        expect(body['content']['dataBase64'], base64Encode([27, 64]));
        return http.Response(
          '{"success":true,"status":"queued","job_id":"j"}',
          202,
        );
      }),
    );
    expect(submissions, 1);
  });

  test('RAW network job also accepts 202', () async {
    final accepted = await http.runWithClient(
      () => LocalPrintService(
        apiToken: 'test',
      ).printRawData(ip: '192.168.1.90', data: [27, 64]),
      () => MockClient(
        (_) async => http.Response(
          '{"success":true,"status":"queued","job_id":"j"}',
          202,
        ),
      ),
    );
    expect(accepted, isTrue);
  });

  test('acknowledged duplicates are accepted, failed jobs are not', () {
    for (final state in ['queued', 'printing', 'done']) {
      expect(
        LocalPrintService.acceptsPrintResponse({
          'duplicate': true,
          'status': state,
          'job_id': 'j',
        }),
        isTrue,
      );
    }
    for (final state in ['failed', 'cancelled', 'unknown']) {
      expect(
        LocalPrintService.acceptsPrintResponse({
          'duplicate': true,
          'status': state,
          'job_id': 'j',
        }),
        isFalse,
      );
    }
    expect(
      LocalPrintService.acceptsPrintResponse({
        'success': true,
        'status': 'failed',
      }),
      isFalse,
    );
  });

  test(
    'MAC resolution sends previous IP and custom port, accepts verified identity',
    () async {
      final ip = await http.runWithClient(
        () => LocalPrintService(apiToken: 'test').resolveIpByMac(
          mac: '00-11-22-33-44-55',
          printerId: 'kitchen-id',
          ip: '192.168.1.80',
          port: 9102,
          skipCache: true,
        ),
        () => MockClient((request) async {
          expect(request.url.path, '/api/printers/resolve-by-mac');
          expect(jsonDecode(request.body), {
            'mac': '00:11:22:33:44:55',
            'printerId': 'kitchen-id',
            'ip': '192.168.1.80',
            'port': 9102,
            'skipCache': true,
          });
          return http.Response(
            jsonEncode({
              'ip': '192.168.1.91',
              'mac': '00:11:22:33:44:55',
              'port': 9102,
              'verified': true,
            }),
            200,
          );
        }),
      );
      expect(ip, '192.168.1.91');
    },
  );

  for (final invalid in [
    {'ip': '192.168.1.91'},
    {
      'ip': '192.168.1.91',
      'mac': '00:11:22:33:44:66',
      'port': 9100,
      'verified': true,
    },
    {
      'ip': '192.168.1.91',
      'mac': '00:11:22:33:44:55',
      'port': 9102,
      'verified': true,
    },
    {
      'ip': '192.168.1.91',
      'mac': '00:11:22:33:44:55',
      'port': 9100,
      'verified': false,
    },
    {
      'ip': '999.168.1.91',
      'mac': '00:11:22:33:44:55',
      'port': 9100,
      'verified': true,
    },
  ]) {
    test('MAC resolver rejects unsafe response $invalid', () async {
      expect(
        await http.runWithClient(
          () => LocalPrintService(
            apiToken: 'test',
          ).resolveIpByMac(mac: '00:11:22:33:44:55'),
          () =>
              MockClient((_) async => http.Response(jsonEncode(invalid), 200)),
        ),
        isNull,
      );
    });
  }

  test('capture preserves custom port and rejects broadcast MAC', () async {
    expect(
      await http.runWithClient(
        () => LocalPrintService(
          apiToken: 'test',
        ).captureMacForIp('192.168.1.80', port: 9102),
        () => MockClient((request) async {
          expect(jsonDecode(request.body), {
            'ip': '192.168.1.80',
            'port': 9102,
          });
          return http.Response(
            '{"ip":"192.168.1.80","mac":"ff:ff:ff:ff:ff:ff"}',
            200,
          );
        }),
      ),
      isNull,
    );
  });

  test('RAW job carries printer identity for agent verification', () async {
    await http.runWithClient(
      () => LocalPrintService(apiToken: 'test').printRawData(
        ip: '192.168.1.91',
        port: 9102,
        data: [27, 64],
        mac: '00:11:22:33:44:55',
        configuredPrinterId: 'kitchen-id',
      ),
      () => MockClient((request) async {
        final body = jsonDecode(request.body);
        expect(body['printerId'], 'kitchen-id');
        expect(body['printer'], {
          'id': 'kitchen-id',
          'type': 'network',
          'ip': '192.168.1.91',
          'port': 9102,
          'mac': '00:11:22:33:44:55',
        });
        return http.Response('{"success":true,"status":"queued"}', 202);
      }),
    );
  });

  for (final status in [200, 502]) {
    test('uncertain RAW delivery is propagated once ($status)', () async {
      var submitted = 0;
      await expectLater(
        http.runWithClient(
          () => LocalPrintService(
            apiToken: 'test',
          ).printRawData(ip: '192.168.1.91', data: [27, 64]),
          () => MockClient((_) async {
            submitted++;
            return http.Response(
              '{"success":false,"deliveryUncertain":true,"safeToRetry":false,"error":"SocketException after write"}',
              status,
            );
          }),
        ),
        throwsA(isA<PrintDeliveryUncertainException>()),
      );
      expect(submitted, 1);
    });
  }

  test('agent response loss does not become a safe retry', () async {
    var submitted = 0;
    await expectLater(
      http.runWithClient(
        () => LocalPrintService(
          apiToken: 'test',
        ).printRawData(ip: '192.168.1.91', data: [27, 64]),
        () => MockClient((_) async {
          submitted++;
          throw http.ClientException('Connection closed before full response');
        }),
      ),
      throwsA(isA<PrintDeliveryUncertainException>()),
    );
    expect(submitted, 1);
  });

  test('unreadable successful response is delivery uncertain', () async {
    await expectLater(
      http.runWithClient(
        () => LocalPrintService(
          apiToken: 'test',
        ).printRawData(ip: '192.168.1.91', data: [27, 64]),
        () => MockClient((_) async => http.Response('truncated response', 200)),
      ),
      throwsA(isA<PrintDeliveryUncertainException>()),
    );
  });

  test(
    'explicit remote host accepts durable 202 through guarded transport',
    () async {
      expect(
        await http.runWithClient(
          () => LocalPrintService(apiToken: 'test').printAtAgent(
            agentUrl: 'http://192.168.1.5:4000',
            payload: {'id': 'stable-remote-id'},
          ),
          () => MockClient((request) async {
            expect(request.url.toString(), 'http://192.168.1.5:4000/print');
            expect(request.headers['Authorization'], 'Bearer test');
            return http.Response('{"success":true,"status":"queued"}', 202);
          }),
        ),
        isTrue,
      );
    },
  );
}
