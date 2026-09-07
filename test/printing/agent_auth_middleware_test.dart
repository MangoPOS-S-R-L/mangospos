import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mangopos/core/agent/mobile_print_agent.dart';

/// Verifica EN VIVO el middleware de autorización del agente Dart en-proceso,
/// levantándolo y pegándole por HTTP real.
///
/// Motivo: leyendo el código parecía que `LocalPrintService` —que manda el JWT
/// de Supabase en `Authorization`— se comía un 403 contra este agente, porque
/// el middleware exigía que el header CONTUVIERA la constante compilada. Eso
/// afecta a las impresoras USB y BLE en Android, iOS y macOS, que son las que
/// dependen del agente; las de red van por socket TCP directo y no pasan por
/// aquí. Un test que hable HTTP de verdad lo confirma sin hardware.
///
/// Dos trampas que costaron un intento cada una:
///   1. `TestWidgetsFlutterBinding` instala un `HttpOverrides` que devuelve 400
///      a TODO sin salir a la red. Sin `HttpOverrides.global = null` el test no
///      prueba nada — la primera versión "pasaba" sin tocar el agente.
///   2. El handler de `/print` TAMBIÉN responde 403 ("Printer no autorizado
///      para tu negocio") cuando la impresora no resuelve. Hay que mirar el
///      CUERPO para saber si el 403 lo puso el middleware o el handler.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MobilePrintAgent agent;
  late String baseUrl;

  setUpAll(() async {
    HttpOverrides.global = null;
    agent = MobilePrintAgent();
    final url = await agent.start(port: 47311);
    expect(url, isNotNull, reason: 'el agente debe levantar en el test');
    baseUrl = url!;
  });

  tearDownAll(() async {
    await agent.stop();
  });

  /// Un JWT cualquiera: lo que importa es que NO contiene la constante.
  const jwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjMifQ.abc123';
  const legacy = 'Bearer MANGOPOS_SECURE_TOKEN_123';

  /// ¿El 403 lo puso el MIDDLEWARE de auth? (el handler tiene los suyos)
  bool rechazadoPorAuth(http.Response r) =>
      r.statusCode == 403 && r.body.contains('Unauthorized');

  Future<http.Response> postPrint({String? authorization}) => http.post(
    Uri.parse('$baseUrl/print'),
    headers: {
      'Content-Type': 'application/json',
      if (authorization != null) 'Authorization': authorization,
    },
    body: jsonEncode({'printerId': '1.2.3.4:9100', 'content': {}}),
  );

  Future<http.Response> getSalon({String? authorization, String? queryToken}) =>
      http.get(
        Uri.parse(
          '$baseUrl/hub/salon?business_id=biz-1'
          '${queryToken == null ? '' : '&token=$queryToken'}',
        ),
        headers: {if (authorization != null) 'Authorization': authorization},
      );

  test('/health no pide auth (por eso el agente "se ve disponible")', () async {
    final r = await http.get(Uri.parse('$baseUrl/health'));
    expect(r.statusCode, 200);
  });

  // EL BUG QUE ESTE ARCHIVO DESTAPÓ: es exactamente el header que manda
  // `LocalPrintService._headers()` cuando hay sesión de Supabase, o sea siempre
  // en operación normal. El middleware lo botaba con 403 por no contener la
  // constante compilada → toda impresión por el AGENTE (USB y BLE) fallaba en
  // Android, iOS y macOS. Las de red no, porque van por socket TCP directo.
  test('POST /print con el JWT de Supabase pasa el middleware', () async {
    final r = await postPrint(authorization: 'Bearer $jwt');
    expect(
      rechazadoPorAuth(r),
      isFalse,
      reason: 'era el 403 que dejaba sin imprimir a las USB/BLE',
    );
  });

  // El JWT se acepta por su FORMA, no por su firma (el agente no tiene el
  // JWT_SECRET). Una credencial cualquiera sigue cayendo.
  test('un bearer que no es JWT ni el legacy sigue rechazado', () async {
    final r = await postPrint(authorization: 'Bearer basura-cualquiera');
    expect(rechazadoPorAuth(r), isTrue);
  });

  test('POST /print con el token legacy SÍ pasa el middleware', () async {
    final r = await postPrint(authorization: legacy);
    expect(rechazadoPorAuth(r), isFalse);
  });

  // El hueco viejo, todavía abierto en los endpoints de impresión: sin header
  // la petición pasa. No se cerró ahí porque endurecerlo rompería cajas
  // mientras LocalPrintService siga mandando el JWT.
  test('POST /print SIN header pasa el middleware (hueco conocido)', () async {
    final r = await postPrint();
    expect(rechazadoPorAuth(r), isFalse);
  });

  // Contraste con el paso 8: en /hub/* el token SÍ es obligatorio.
  group('endpoints del Hub (paso 8)', () {
    test('sin token → rechazado', () async {
      expect(rechazadoPorAuth(await getSalon()), isTrue);
    });

    test('con token inventado → rechazado', () async {
      final r = await getSalon(authorization: 'Bearer no-soy-el-token');
      expect(rechazadoPorAuth(r), isTrue);
    });

    test('con el legacy → pasa (rollout)', () async {
      expect(rechazadoPorAuth(await getSalon(authorization: legacy)), isFalse);
    });

    // El WebSocket no puede mandar cabeceras en el handshake, por eso el token
    // se acepta por query. Se verifica sobre un endpoint HTTP porque lo que
    // importa es que el middleware sepa leerlo de ahí.
    test('token por query → pasa (es el camino del WebSocket)', () async {
      final r = await getSalon(queryToken: 'MANGOPOS_SECURE_TOKEN_123');
      expect(rechazadoPorAuth(r), isFalse);
    });

    test('/hub/health sigue abierto (handshake de descubrimiento)', () async {
      final r = await http.get(Uri.parse('$baseUrl/hub/health'));
      expect(r.statusCode, 200);
    });
  });
}
