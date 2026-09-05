import 'dart:typed_data';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/network/mango_http_overrides.dart';
import 'package:mangopos/core/network/network_time.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

/// Certificado de mentira para ejercitar la politica sin montar un servidor
/// TLS: lo unico que la politica mira son las fechas de validez.
class _FakeCert implements X509Certificate {
  _FakeCert({required this.startValidity, required this.endValidity});

  @override
  final DateTime startValidity;
  @override
  final DateTime endValidity;

  @override
  Uint8List get der => Uint8List(0);
  @override
  String get pem => '';
  @override
  Uint8List get sha1 => Uint8List(0);
  @override
  String get subject => 'CN=mangopos.do';
  @override
  String get issuer => "C=US, O=Let's Encrypt, CN=YE1";
}

void main() {
  const backendHost = 'supabase.mangopos.do';

  // `DateTime.now()` en el test hace de reloj (mal puesto) del equipo. El
  // certificado, en cambio, se emite alrededor de la hora REAL de la red, que
  // es `now + skew` invertido. Este helper arma esa ventana: ~90 dias de Let's
  // Encrypt, renovada 6 dias antes de la hora real.
  final now = DateTime.now().toUtc();
  _FakeCert certEmitidoConReloj(Duration skew) {
    final realNow = now.subtract(skew);
    return _FakeCert(
      startValidity: realNow.subtract(const Duration(days: 6)),
      endValidity: realNow.add(const Duration(days: 84)),
    );
  }

  late MangoHttpOverrides policy;

  setUp(() {
    policy = MangoHttpOverrides.debugFor(backendHost);
    NetworkTime.debugSetSkew(null);
    MangoHttpOverrides.clockBypassUsed = false;
  });

  tearDown(() => NetworkTime.debugSetSkew(null));

  group('politica TLS tolerante al reloj', () {
    test('acepta cuando el equipo esta atrasado antes de la emision', () {
      // Caso real del POS Windows: el equipo cree que estamos 30 dias atras,
      // o sea antes de que el certificado se emitiera.
      const skew = Duration(days: -30);
      NetworkTime.debugSetSkew(skew);

      final r = policy.debugEvaluate(
        certEmitidoConReloj(skew),
        backendHost,
        443,
      );
      expect(r, isTrue);
      expect(MangoHttpOverrides.clockBypassUsed, isTrue);
    });

    test('acepta cuando el equipo esta adelantado mas alla del vencimiento', () {
      const skew = Duration(days: 400);
      NetworkTime.debugSetSkew(skew);
      expect(
        policy.debugEvaluate(certEmitidoConReloj(skew), backendHost, 443),
        isTrue,
      );
    });

    test('RECHAZA si el reloj del equipo esta bien', () {
      // Con la hora correcta el fallo era otra cosa (cadena rota, MITM) y no
      // se perdona: es la garantia de que esto no debilita TLS en un equipo
      // sano.
      NetworkTime.debugSetSkew(Duration.zero);
      expect(
        policy.debugEvaluate(certEmitidoConReloj(Duration.zero), backendHost, 443),
        isFalse,
      );
      expect(MangoHttpOverrides.clockBypassUsed, isFalse);
    });

    test('RECHAZA un certificado vencido de verdad', () {
      // El reloj esta mal Y ademas el certificado esta vencido contra la hora
      // real: se rechaza igual, la tolerancia es solo para el reloj.
      const skew = Duration(days: -30);
      NetworkTime.debugSetSkew(skew);
      final realNow = now.subtract(skew);
      final vencido = _FakeCert(
        startValidity: realNow.subtract(const Duration(days: 200)),
        endValidity: realNow.subtract(const Duration(days: 110)),
      );
      expect(policy.debugEvaluate(vencido, backendHost, 443), isFalse);
    });

    test('RECHAZA un host que no es el backend', () {
      const skew = Duration(days: -30);
      NetworkTime.debugSetSkew(skew);
      expect(
        policy.debugEvaluate(
          certEmitidoConReloj(skew),
          'evil.example.com',
          443,
        ),
        isFalse,
      );
    });

    test('RECHAZA si no hay hora de red con que comparar', () {
      NetworkTime.debugSetSkew(null);
      expect(
        policy.debugEvaluate(
          certEmitidoConReloj(const Duration(days: -30)),
          backendHost,
          443,
        ),
        isFalse,
      );
    });
  });

  group('NetworkTime', () {
    test('marca el reloj como corrido solo pasada la tolerancia', () {
      NetworkTime.debugSetSkew(const Duration(minutes: 1));
      expect(NetworkTime.isDeviceClockWrong, isFalse);

      NetworkTime.debugSetSkew(const Duration(hours: 3));
      expect(NetworkTime.isDeviceClockWrong, isTrue);

      NetworkTime.debugSetSkew(const Duration(days: -30));
      expect(NetworkTime.isDeviceClockWrong, isTrue);
      expect(NetworkTime.skew!.isNegative, isTrue, reason: 'atrasado');
    });

    test('sin sondeo no inventa una hora', () {
      NetworkTime.debugSetSkew(null);
      expect(NetworkTime.isSynced, isFalse);
      expect(NetworkTime.instantOrNull(), isNull);
    });
  });

  group('mensajes de TLS', () {
    test('vencido / aun no valido manda a la fecha y hora', () {
      expect(
        FriendlyError.from(
          const HandshakeException(
            'Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED: '
            'certificate is not yet valid(handshake.cc:393))',
          ),
        ),
        FriendlyError.tlsClock,
      );
      expect(
        FriendlyError.from(
          const HandshakeException(
            'Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED: '
            'certificate has expired(handshake.cc:393))',
          ),
        ),
        FriendlyError.tlsClock,
      );
    });

    test('cadena de confianza rota NO manda a la fecha y hora', () {
      final msg = FriendlyError.from(
        const HandshakeException(
          'Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED: '
          'unable to get local issuer certificate(handshake.cc:393))',
        ),
      );
      expect(msg, FriendlyError.tlsTrust);
      expect(msg.toLowerCase(), isNot(contains('fecha')));
    });

    test('handshake caido sin motivo de certificado se trata como red', () {
      expect(
        FriendlyError.from(
          const HandshakeException('Connection terminated during handshake'),
        ),
        FriendlyError.tlsCertificate,
      );
    });

    test('ningun mensaje de TLS excede el largo de pantalla', () {
      for (final msg in [
        FriendlyError.tlsClock,
        FriendlyError.tlsTrust,
        FriendlyError.tlsCertificate,
      ]) {
        expect(msg.length, lessThanOrEqualTo(FriendlyError.maxLength));
        expect(FriendlyError.isTechnical(msg), isFalse);
      }
    });
  });
}
