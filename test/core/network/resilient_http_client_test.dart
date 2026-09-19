import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/network/resilient_http_client.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';

const _base = 'https://supabase.example.do';

Uri _u(String path) => Uri.parse('$_base$path');

void main() {
  group('sin red confirmada', () {
    test('las consultas fallan al instante sin tocar la red', () async {
      var calls = 0;
      var reports = 0;
      final client = ResilientHttpClient(
        inner: MockClient((_) async {
          calls++;
          return http.Response('[]', 200);
        }),
        isKnownOffline: () => true,
        onTransportFailure: () => reports++,
      );

      final sw = Stopwatch()..start();
      await expectLater(
        client.get(_u('/rest/v1/orders')),
        throwsA(isA<OfflineShortCircuitException>()),
      );
      await expectLater(
        client.post(_u('/auth/v1/token')),
        throwsA(isA<OfflineShortCircuitException>()),
      );
      sw.stop();

      expect(calls, 0);
      expect(sw.elapsedMilliseconds, lessThan(500));
      // Es nuestro propio corte, no una falla nueva de la red.
      expect(reports, 0);
    });

    test('el resto del sistema lo trata como caída de red', () {
      final e = OfflineShortCircuitException('/rest/v1/rpc/fn');
      expect(e, isA<TimeoutException>());
      expect(OfflinePosService.isTransportError(e), isTrue);
      expect(ResilientHttpClient.isTransportFailure(e), isTrue);
    });

    test('storage y edge functions no se tocan', () async {
      var calls = 0;
      final client = ResilientHttpClient(
        inner: MockClient((_) async {
          calls++;
          return http.Response('ok', 200);
        }),
        isKnownOffline: () => true,
      );

      expect((await client.get(_u('/storage/v1/object/x'))).body, 'ok');
      expect((await client.post(_u('/functions/v1/emit'))).body, 'ok');
      expect(calls, 2);
    });
  });

  group('red muerta sin detectar todavía', () {
    test('una consulta colgada vence y avisa al detector', () async {
      var reports = 0;
      final client = ResilientHttpClient(
        inner: MockClient((_) => Completer<http.Response>().future),
        onTransportFailure: () => reports++,
        restTimeout: const Duration(milliseconds: 80),
      );

      await expectLater(
        client.get(_u('/rest/v1/orders')),
        throwsA(isA<TimeoutException>()),
      );
      expect(reports, 1);
    });

    test('el refresco de sesión también tiene límite', () async {
      final client = ResilientHttpClient(
        inner: MockClient((_) => Completer<http.Response>().future),
        authTimeout: const Duration(milliseconds: 80),
      );

      await expectLater(
        client.post(_u('/auth/v1/token?grant_type=refresh_token')),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('un error de socket se propaga igual y avisa', () async {
      var reports = 0;
      final client = ResilientHttpClient(
        inner: MockClient(
          (_) async => throw http.ClientException(
            'SocketException: Failed host lookup',
          ),
        ),
        onTransportFailure: () => reports++,
      );

      await expectLater(
        client.get(_u('/rest/v1/orders')),
        throwsA(isA<http.ClientException>()),
      );
      expect(reports, 1);
    });

    test('un cuerpo que deja de llegar corta en vez de colgar', () async {
      var reports = 0;
      final body = StreamController<List<int>>();
      final client = ResilientHttpClient(
        inner: MockClient.streaming(
          (_, _) async => http.StreamedResponse(body.stream, 200),
        ),
        onTransportFailure: () => reports++,
        bodyIdleTimeout: const Duration(milliseconds: 80),
      );

      body.add(utf8.encode('[{"id":'));
      await expectLater(
        client.get(_u('/rest/v1/orders')),
        throwsA(isA<TimeoutException>()),
      );
      expect(reports, 1);
      await body.close();
    });

    test('las rutas sin límite siguen esperando', () async {
      final pending = Completer<http.Response>();
      final client = ResilientHttpClient(
        inner: MockClient((_) => pending.future),
        restTimeout: const Duration(milliseconds: 20),
        authTimeout: const Duration(milliseconds: 20),
      );

      var done = false;
      final call = client
          .post(_u('/functions/v1/emit'))
          .then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(done, isFalse);

      pending.complete(http.Response('ok', 200));
      await call;
      expect(done, isTrue);
    });
  });

  group('servidor responde', () {
    test('un 500 se devuelve tal cual y no cuenta como caída', () async {
      var reports = 0;
      final client = ResilientHttpClient(
        inner: MockClient((_) async => http.Response('boom', 500)),
        onTransportFailure: () => reports++,
      );

      final res = await client.get(_u('/rest/v1/orders'));
      expect(res.statusCode, 500);
      expect(res.body, 'boom');
      expect(reports, 0);
    });

    test('conserva estado, cabeceras y cuerpo', () async {
      final client = ResilientHttpClient(
        inner: MockClient(
          (_) async => http.Response(
            '[{"id":1}]',
            206,
            headers: {'content-range': '0-0/1'},
          ),
        ),
      );

      final res = await client.get(_u('/rest/v1/orders'));
      expect(res.statusCode, 206);
      expect(res.headers['content-range'], '0-0/1');
      expect(jsonDecode(res.body), [
        {'id': 1},
      ]);
    });
  });
}
