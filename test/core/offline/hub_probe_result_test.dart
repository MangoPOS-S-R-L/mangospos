// Diagnóstico de un equipo encontrado en la red.
//
// Nace de una prueba real en tablet (2026-09-28): el buscador listó 5 equipos,
// el dueño eligió el correcto por IP (.173), y el modal respondió "revisa que
// esté encendida y en la misma red" — cuando el equipo estaba encendido, en la
// misma red y respondía al ping. Lo que pasaba es que NINGUNO tenía rol de
// Hub, y "no responde" y "responde pero no es la caja" caían en el mismo
// mensaje. Se arreglan de formas OPUESTAS (revisar el wifi vs. configurar ese
// equipo), así que tienen que distinguirse.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/hub/hub_client.dart';

/// Responde `/hub/health` según [byHostPort] ("ip:puerto"). Un host ausente
/// simula un equipo apagado.
http.Client _fake(Map<String, Map<String, dynamic>> byHostPort) {
  return MockClient((request) async {
    final key = '${request.url.host}:${request.url.port}';
    final body = byHostPort[key];
    if (body == null) return http.Response('', 404);
    return http.Response(jsonEncode(body), 200);
  });
}

void main() {
  const biz = 'biz-1';

  Future<HubProbeResult> probe(
    Map<String, Map<String, dynamic>> red,
    String ip,
  ) {
    return HubClient(httpClient: _fake(red))
        .probeCandidate(ip, businessId: biz);
  }

  test('la caja de este negocio se reconoce', () async {
    expect(
      await probe({
        '10.101.0.173:4000': {'role': 'hub', 'business_id': biz},
      }, '10.101.0.173'),
      HubProbeResult.hub,
    );
  });

  test('un agente de impresión NO se confunde con la caja', () async {
    // El caso de la prueba real: responde 200, pero su rol es `pos`.
    expect(
      await probe({
        '10.101.0.27:4000': {'role': 'pos', 'business_id': biz},
      }, '10.101.0.27'),
      HubProbeResult.notHub,
    );
  });

  test('la caja de OTRO negocio se distingue', () async {
    // Engancharse mostraría mesas ajenas: hay que decirlo, no fallar seco.
    expect(
      await probe({
        '10.101.0.95:4000': {'role': 'hub', 'business_id': 'otro'},
      }, '10.101.0.95'),
      HubProbeResult.otherBusiness,
    );
  });

  test('un equipo apagado queda como no alcanzable', () async {
    expect(await probe(const {}, '10.101.0.9'), HubProbeResult.unreachable);
  });

  test('encuentra el Hub en 4100 aunque el 4000 sea el de impresión', () async {
    // Windows: el agente Node ocupa el 4000 y el Hub Dart vive en el 4100.
    expect(
      await probe({
        '10.101.0.173:4000': {'role': 'pos', 'business_id': biz},
        '10.101.0.173:4100': {'role': 'hub', 'business_id': biz},
      }, '10.101.0.173'),
      HubProbeResult.hub,
    );
  });

  test('se queda con el resultado que más explica', () async {
    // Un puerto muerto y otro que dice "no soy hub": lo útil es lo segundo,
    // porque manda a configurar el equipo en vez de a revisar la red.
    expect(
      await probe({
        '10.101.0.173:4100': {'role': 'pos', 'business_id': biz},
      }, '10.101.0.173'),
      HubProbeResult.notHub,
    );
  });

  test('le dice al equipo qué negocio pregunta', () async {
    // Cinturón del bug de la tablet: un equipo que todavía no dejó su negocio
    // en disco respondía 'pos' y nadie lo reconocía como la caja. Ahora el
    // cliente manda el suyo y el equipo resuelve su rol con él.
    String? visto;
    final client = HubClient(
      httpClient: MockClient((request) async {
        visto = request.url.queryParameters['business_id'];
        return http.Response(
          jsonEncode({'role': 'hub', 'business_id': biz}),
          200,
        );
      }),
    );
    expect(
      await client.probeCandidate('10.101.0.173', businessId: biz),
      HubProbeResult.hub,
    );
    expect(visto, biz);
  });

  test('respeta el puerto que el usuario escribió', () async {
    expect(
      await probe({
        '10.101.0.50:8080': {'role': 'hub', 'business_id': biz},
      }, 'http://10.101.0.50:8080'),
      HubProbeResult.hub,
    );
  });
}
