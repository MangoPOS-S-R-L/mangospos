import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_event_stream.dart';
import 'package:mangopos/core/offline/hub/hub_lan_token.dart';

/// Tests del token LAN por negocio (paso 8 offline).
///
/// Lo que había antes: una constante compilada, la misma para TODOS los
/// negocios del país. Quien la sacara del binario podía hablarle al Hub de
/// cualquier local — leer el salón y las órdenes, e inyectar ops en el op-log
/// que el uplink después sube a Supabase como ventas reales.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('validación de tokens', () {
    late HubLanTokenService service;

    setUp(() {
      service = HubLanTokenService(
        readToken: _FakeSettings({'biz-1': 'tok-1'}).read,
      );
    });

    test('acepta el token del negocio', () async {
      expect(await service.isValid('biz-1', 'tok-1'), isTrue);
    });

    test('rechaza un token inventado', () async {
      expect(await service.isValid('biz-1', 'lo-que-sea'), isFalse);
    });

    // El caso que motivó todo: sin header no debe pasar nada.
    test('rechaza el token vacío', () async {
      expect(await service.isValid('biz-1', ''), isFalse);
    });

    // Durante el rollout hay cajas con builds viejos que solo saben el legacy;
    // si el Hub las rechaza, el local se parte en dos.
    test('acepta el legacy mientras dure el rollout', () async {
      expect(await service.isValid('biz-1', kLegacyHubLanToken), isTrue);
    });

    test('el token de un negocio NO sirve en otro', () async {
      final s = HubLanTokenService(
        readToken: _FakeSettings({'biz-1': 'tok-1', 'biz-2': 'tok-2'}).read,
      );
      expect(await s.isValid('biz-2', 'tok-1'), isFalse);
      expect(await s.isValid('biz-2', 'tok-2'), isTrue);
    });
  });

  group('resolución', () {
    test('devuelve el token del negocio', () async {
      final s = HubLanTokenService(
        readToken: _FakeSettings({'biz-1': 'tok-1'}).read,
      );
      expect(await s.tokenFor('biz-1'), 'tok-1');
    });

    // Migración 20260907_0010 sin aplicar: el getter devuelve vacío. No se
    // puede dejar al local incomunicado por eso.
    test('sin lan_token cae al legacy', () async {
      final s = HubLanTokenService(readToken: _FakeSettings(const {}).read);
      expect(await s.tokenFor('biz-1'), kLegacyHubLanToken);
    });

    test('si la consulta truena, cae al legacy', () async {
      final s = HubLanTokenService(
        readToken: _FakeSettings(const {}, boom: true).read,
      );
      expect(await s.tokenFor('biz-1'), kLegacyHubLanToken);
    });

    test('sin negocio activo cae al legacy', () async {
      final s = HubLanTokenService(
        readToken: _FakeSettings({'biz-1': 'tok-1'}).read,
      );
      expect(await s.tokenFor(''), kLegacyHubLanToken);
    });

    test('cachea: no vuelve a consultar el mismo negocio', () async {
      final fake = _FakeSettings({'biz-1': 'tok-1'});
      final s = HubLanTokenService(readToken: fake.read);
      await s.tokenFor('biz-1');
      await s.tokenFor('biz-1');
      await s.tokenFor('biz-1');
      expect(fake.calls, 1);
    });

    test('invalidate obliga a releer (rotación del token)', () async {
      final fake = _FakeSettings({'biz-1': 'tok-1'});
      final s = HubLanTokenService(readToken: fake.read);
      await s.tokenFor('biz-1');
      s.invalidate('biz-1');
      fake.tokens['biz-1'] = 'tok-rotado';
      expect(await s.tokenFor('biz-1'), 'tok-rotado');
      expect(fake.calls, 2);
    });
  });

  // El handshake de WebSocket no admite cabeceras en todas las plataformas, así
  // que el feed manda el token por query. Sin esto, endurecer `/hub/*` habría
  // matado las actualizaciones en vivo del KDS y del salón.
  group('token en la URL del WebSocket', () {
    test('http pasa a ws y agrega el token', () {
      final uri = HubEventStream.wsUrlFor('http://10.0.0.5:4000', token: 't');
      expect(uri.scheme, 'ws');
      expect(uri.path, '/hub/events');
      expect(uri.queryParameters['token'], 't');
    });

    test('sin token la URL queda limpia', () {
      final uri = HubEventStream.wsUrlFor('http://10.0.0.5:4000');
      expect(uri.queryParameters.containsKey('token'), isFalse);
    });

    test('tolera la barra final', () {
      final uri = HubEventStream.wsUrlFor('http://10.0.0.5:4000/', token: 't');
      expect(uri.toString(), 'ws://10.0.0.5:4000/hub/events?token=t');
    });
  });
}

class _FakeSettings {
  _FakeSettings(Map<String, String> tokens, {this.boom = false})
    : tokens = Map.of(tokens);

  final Map<String, String> tokens;
  final bool boom;
  int calls = 0;

  Future<String> read(String businessId) async {
    calls++;
    if (boom) throw Exception('sin red');
    return tokens[businessId] ?? '';
  }
}
