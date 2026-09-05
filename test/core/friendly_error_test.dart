import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

void main() {
  group('FriendlyError.humanize', () {
    test('el error real del login queda en una sola frase entendible', () {
      const raw =
          "ClientException with SocketException: Failed host lookup: "
          "'supabase.mangopos.do' (OS Error: Host desconocido, errno = 11001), "
          "uri=https://supabase.mangopos.do/auth/v1/token?grant_type=password";

      final message = FriendlyError.humanize(raw);

      expect(message, FriendlyError.connection);
      expect(message.contains('http'), isFalse);
      expect(message.contains('errno'), isFalse);
      expect(message.contains('Exception'), isFalse);
    });

    test('conserva la parte escrita a mano y reemplaza la cola tecnica', () {
      final message = FriendlyError.humanize(
        'No se pudo imprimir: SocketException: Connection refused (errno = 61)',
      );

      expect(message, 'No se pudo imprimir. ${FriendlyError.connection}');
    });

    test('un prefijo generico no ensucia el mensaje', () {
      expect(
        FriendlyError.humanize('Error: TimeoutException after 0:00:15.000000'),
        FriendlyError.timeout,
      );
    });

    test('deja intacto un mensaje ya amigable', () {
      const human = 'Debes abrir la caja antes de abrir una mesa.';
      expect(FriendlyError.humanize(human), human);
    });

    test('respeta el texto de un throw Exception escrito a mano', () {
      expect(
        FriendlyError.humanize('Exception: El correo ya está registrado.'),
        'El correo ya está registrado.',
      );
    });

    test('un socket contra una impresora habla de la red local', () {
      final message = FriendlyError.humanize(
        'No se pudo imprimir: SocketException: Connection timed out '
        '(OS Error: Operation timed out, errno = 60), '
        'address = 192.168.1.50, port = 9100',
      );

      expect(message, 'No se pudo imprimir. ${FriendlyError.lanDevice}');
    });

    test('un error de tipo de Dart no llega a pantalla', () {
      final message = FriendlyError.humanize(
        "No se pudo guardar el cambio: type 'Null' is not a subtype of type "
        "'String'",
      );

      expect(message, 'No se pudo guardar el cambio. ${FriendlyError.retry}');
      expect(message.contains('subtype'), isFalse);
    });

    test('recorta mensajes larguisimos', () {
      final message = FriendlyError.humanize('x' * 500);
      expect(message.length, lessThanOrEqualTo(FriendlyError.maxLength));
    });

    test('nunca devuelve vacio', () {
      expect(FriendlyError.humanize('   '), FriendlyError.unknown);
    });
  });

  group('FriendlyError.from', () {
    test('credenciales invalidas', () {
      expect(
        FriendlyError.from(Exception('Invalid login credentials')),
        FriendlyError.badCredentials,
      );
    });

    test('sesion vencida', () {
      expect(
        FriendlyError.from(Exception('JWT expired')),
        FriendlyError.expiredSession,
      );
    });

    test('rate limit de supabase', () {
      expect(
        FriendlyError.from(
          Exception('For security purposes, you can only request this after 55 seconds'),
        ),
        FriendlyError.tooManyAttempts,
      );
    });

    test('permisos / RLS', () {
      expect(
        FriendlyError.from(
          Exception('new row violates row-level security policy for table "orders"'),
        ),
        FriendlyError.noPermission,
      );
    });

    test('servidor caido', () {
      expect(
        FriendlyError.from(Exception('AuthRetryableFetchException: Bad Gateway')),
        FriendlyError.serverUnavailable,
      );
    });

    test('datos locales corruptos', () {
      expect(
        FriendlyError.from(const FormatException('bad json')),
        FriendlyError.corruptedLocalData,
      );
    });

    test('null cae en el mensaje generico', () {
      expect(FriendlyError.from(null), FriendlyError.unknown);
    });

    test('un error desconocido no filtra su texto crudo', () {
      final message = FriendlyError.from(
        StateError('Bad state: no element at index 7 in _GrowableList'),
      );
      expect(message, FriendlyError.unknown);
    });
  });

  group('FriendlyError.isTechnical', () {
    test('detecta texto de excepcion', () {
      expect(FriendlyError.isTechnical('PostgrestException(code: 42501)'), isTrue);
    });

    test('no marca texto humano', () {
      expect(FriendlyError.isTechnical('No hay una orden activa.'), isFalse);
    });
  });
}
