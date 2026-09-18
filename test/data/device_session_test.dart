import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/device_session.dart';
import 'package:mangopos/data/repositories/device_sessions_repository.dart';

/// Contrato de "Dispositivos conectados" (migración 20260918_0001) del lado
/// del modelo: lo que devuelve fn_device_sessions_list y fn_device_session_ping.
void main() {
  Map<String, dynamic> row([Map<String, dynamic> extra = const {}]) => {
        'id': 's1',
        'device_id': 'd1',
        'label': null,
        'device_name': 'Android',
        'hostname': null,
        'platform': 'android',
        'os_version': 'Linux 5.10',
        'app_version': '1.8.3+10803',
        'user_id': 'u1',
        'user_email': 'cajero@x.do',
        'user_name': 'Carla Pérez',
        'employee_id': null,
        'employee_name': null,
        'signed_in_at': '2026-09-18T14:00:00+00:00',
        'last_seen_at': '2026-09-18T14:05:00+00:00',
        'idle_seconds': 30,
        'revoked_at': null,
        'revoked_by_name': null,
        ...extra,
      };

  group('DeviceSession.fromMap', () {
    test('parsea la fila del RPC', () {
      final s = DeviceSession.fromMap(row());
      expect(s.id, 's1');
      expect(s.deviceId, 'd1');
      expect(s.appVersion, '1.8.3+10803');
      expect(s.signedInAt, DateTime.utc(2026, 9, 18, 14));
      expect(s.idleSeconds, 30);
      expect(s.isRevokePending, isFalse);
    });

    test('texto vacío o en blanco cuenta como ausente', () {
      final s = DeviceSession.fromMap(row({'label': '  ', 'user_name': ''}));
      expect(s.label, isNull);
      expect(s.userName, isNull);
      expect(s.accountLabel, 'cajero@x.do');
    });

    test('idle_seconds ausente no rompe', () {
      final s = DeviceSession.fromMap(row({'idle_seconds': null}));
      expect(s.idleSeconds, 0);
    });
  });

  group('estado', () {
    test('en línea mientras el último ping tenga menos de 7 min', () {
      expect(DeviceSession.fromMap(row({'idle_seconds': 419})).isOnline, isTrue);
      expect(DeviceSession.fromMap(row({'idle_seconds': 420})).isOnline, isFalse);
    });

    test('revoked_at marca cierre pendiente', () {
      final s = DeviceSession.fromMap(
        row({'revoked_at': '2026-09-18T14:06:00+00:00'}),
      );
      expect(s.isRevokePending, isTrue);
    });
  });

  group('displayName', () {
    test('la etiqueta del admin manda', () {
      final s = DeviceSession.fromMap(
        row({'label': 'Tablet barra', 'hostname': 'CAJA-01'}),
      );
      expect(s.displayName, 'Tablet barra');
    });

    test('sin etiqueta: nombre de la app más hostname', () {
      final s = DeviceSession.fromMap(
        row({'device_name': 'PC', 'hostname': 'CAJA-01'}),
      );
      expect(s.displayName, 'PC · CAJA-01');
    });

    test('sin nada: "Dispositivo"', () {
      final s = DeviceSession.fromMap(row({'device_name': null}));
      expect(s.displayName, 'Dispositivo');
    });
  });

  test('formatIdle', () {
    expect(formatIdle(0), 'hace un momento');
    expect(formatIdle(59), 'hace un momento');
    expect(formatIdle(60), 'hace 1 min');
    expect(formatIdle(3599), 'hace 59 min');
    expect(formatIdle(3600), 'hace 1 h');
    expect(formatIdle(86399), 'hace 23 h');
    expect(formatIdle(86400), 'hace 1 día');
    expect(formatIdle(3 * 86400), 'hace 3 días');
  });

  group('DeviceSessionPingResult.fromResponse', () {
    test('lee revoked y closed', () {
      final r = DeviceSessionPingResult.fromResponse({
        'session_id': 's1',
        'revoked': true,
        'closed': false,
      });
      expect(r.revoked, isTrue);
      expect(r.closed, isFalse);
    });

    test('respuesta rara = nada que hacer (nunca desloguea por error)', () {
      for (final bad in [null, 'x', 1, <dynamic>[]]) {
        final r = DeviceSessionPingResult.fromResponse(bad);
        expect(r.revoked, isFalse, reason: '$bad');
        expect(r.closed, isFalse, reason: '$bad');
      }
      // Solo `true` literal cuenta: un 'true' string no cierra la sesión.
      final r = DeviceSessionPingResult.fromResponse({'revoked': 'true'});
      expect(r.revoked, isFalse);
    });
  });

  group('humanizeError', () {
    test('mensajes conocidos', () {
      expect(
        DeviceSessionsRepository.humanizeError(Exception('ACCESS_DENIED')),
        contains('dueño o un administrador'),
      );
      expect(
        DeviceSessionsRepository.humanizeError(
          Exception('PGRST202 Could not find the function'),
        ),
        contains('no está instalada'),
      );
    });
  });
}
