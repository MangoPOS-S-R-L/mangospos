import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mangopos/core/services/local_print_service.dart';

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
}
