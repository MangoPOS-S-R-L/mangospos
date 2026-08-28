// Pruebas del estado de acceso (bloqueo por falta de pago).
//
// Lo que se cubre acá es lo que NO puede fallar: que el kill switch apagado
// no bloquee a nadie, que un snapshot viejo bloquee (para que desconectar el
// internet no sea la vía de escape) y que el snapshot sobreviva el viaje de
// ida y vuelta al disco.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/account_access_state.dart';
import 'package:mangopos/data/repositories/account_access_repository.dart';

Map<String, dynamic> _rpc({
  String state = 'ok',
  String reason = 'none',
  bool enforced = true,
  String? graceEndsAt,
  String? lockedAt,
  int offlineMaxDays = 7,
  String? customerMessage,
}) {
  return {
    'business_id': 'b-1',
    'state': state,
    'reason': reason,
    'enforced': enforced,
    'locked_at': lockedAt,
    'grace_ends_at': graceEndsAt,
    'scheduled_lock_at': null,
    'override_until': null,
    'customer_message': customerMessage,
    'contact_name': 'Luis',
    'contact_phone': '809-000-0000',
    'contact_email': null,
    'offline_max_days': offlineMaxDays,
    'plan_name': 'Básico',
    'amount_cents': 299999,
    'currency_code': 'DOP',
    'next_billing_date': '2026-09-01',
    'billing_status': 'past_due',
    'checked_at': '2026-08-25T12:00:00Z',
  };
}

void main() {
  group('enforcement', () {
    test('con enforced=false no bloquea ni avisa aunque esté locked', () {
      final s = AccountAccessState.fromRpc(
        _rpc(state: 'locked', reason: 'manual_lock', enforced: false),
      );
      expect(s.level, AccessLevel.locked);
      expect(s.blocksApp, isFalse, reason: 'el kill switch apagado manda');
      expect(s.showsBanner, isFalse);
    });

    test('con enforced=true y locked sí bloquea', () {
      final s = AccountAccessState.fromRpc(
        _rpc(state: 'locked', reason: 'subscription_suspended'),
      );
      expect(s.blocksApp, isTrue);
      expect(s.showsBanner, isFalse, reason: 'bloqueado no muestra banner');
    });

    test('warning y grace muestran banner, no bloquean', () {
      for (final level in ['warning', 'grace']) {
        final s = AccountAccessState.fromRpc(
          _rpc(state: level, reason: 'payment_overdue'),
        );
        expect(s.blocksApp, isFalse, reason: level);
        expect(s.showsBanner, isTrue, reason: level);
      }
    });

    test('unrestricted nunca bloquea', () {
      final s = AccountAccessState.unrestricted('b-1');
      expect(s.blocksApp, isFalse);
      expect(s.showsBanner, isFalse);
      expect(s.isStale, isFalse);
    });
  });

  group('antigüedad del snapshot', () {
    AccountAccessState aged(
      Duration age, {
      bool enforced = true,
      int offlineMaxDays = 7,
      String state = 'ok',
    }) {
      return AccountAccessState.fromRpc(
        _rpc(state: state, enforced: enforced, offlineMaxDays: offlineMaxDays),
        cachedAt: DateTime.now().subtract(age),
        fromCache: true,
      );
    }

    test('fresco no está viejo', () {
      expect(aged(const Duration(hours: 3)).isStale, isFalse);
    });

    test('pasado el límite queda viejo', () {
      expect(aged(const Duration(days: 8)).isStale, isTrue);
    });

    test('justo en el límite queda viejo', () {
      expect(aged(const Duration(days: 7, minutes: 1)).isStale, isTrue);
    });

    test('sin enforcement nunca queda viejo', () {
      expect(aged(const Duration(days: 90), enforced: false).isStale, isFalse);
    });

    test('offlineMaxDays=0 desactiva el bloqueo por falta de verificación', () {
      expect(aged(const Duration(days: 90), offlineMaxDays: 0).isStale, isFalse);
    });

    test('toStale bloquea y conserva el contacto', () {
      final stale = aged(const Duration(days: 10)).toStale();
      expect(stale.level, AccessLevel.locked);
      expect(stale.reason, AccessReason.verificationStale);
      expect(stale.blocksApp, isTrue);
      expect(stale.contactPhone, '809-000-0000');
      expect(
        stale.body,
        contains('sin conectarse'),
        reason: 'el mensaje del operador no aplica a este motivo',
      );
    });
  });

  group('mensaje al cliente', () {
    test('el mensaje del operador gana sobre el texto por defecto', () {
      final s = AccountAccessState.fromRpc(
        _rpc(
          state: 'locked',
          reason: 'payment_overdue',
          customerMessage: 'Llama a Luis al 809-555-1212.',
        ),
      );
      expect(s.body, 'Llama a Luis al 809-555-1212.');
    });

    test('sin mensaje propio cae al texto del motivo', () {
      final s = AccountAccessState.fromRpc(
        _rpc(state: 'locked', reason: 'subscription_suspended'),
      );
      expect(s.body, contains('cobrar tu mensualidad'));
      expect(s.title, 'Tu suscripción está suspendida');
    });
  });

  group('regresiva', () {
    test('días, horas y minutos', () {
      final cases = <Duration, String>{
        const Duration(days: 3, hours: 2): '3 días',
        const Duration(days: 1, hours: 1): '1 día',
        const Duration(hours: 8): '8 horas',
        const Duration(hours: 1, minutes: 5): '1 hora',
        const Duration(minutes: 45): '45 minutos',
      };
      cases.forEach((d, expected) {
        final s = AccountAccessState.fromRpc(
          _rpc(
            state: 'grace',
            reason: 'payment_overdue',
            graceEndsAt: DateTime.now()
                .add(d)
                .add(const Duration(seconds: 30))
                .toUtc()
                .toIso8601String(),
          ),
        );
        expect(s.countdownLabel, expected, reason: '$d');
      });
    });

    test('plazo vencido no devuelve regresiva', () {
      final s = AccountAccessState.fromRpc(
        _rpc(
          state: 'locked',
          reason: 'payment_overdue',
          graceEndsAt: DateTime.now()
              .subtract(const Duration(days: 1))
              .toUtc()
              .toIso8601String(),
        ),
      );
      expect(s.countdownLabel, isNull);
      expect(s.timeRemaining, isNull);
    });

    test('sin plazo no devuelve regresiva', () {
      final s = AccountAccessState.fromRpc(_rpc(state: 'locked'));
      expect(s.countdownLabel, isNull);
    });
  });

  group('snapshot local', () {
    test('sobrevive el viaje a disco conservando lo que importa', () {
      final original = AccountAccessState.fromRpc(
        _rpc(
          state: 'grace',
          reason: 'payment_overdue',
          lockedAt: '2026-08-20T10:00:00Z',
          graceEndsAt: '2026-08-30T10:00:00Z',
          customerMessage: 'Regulariza antes del 30.',
        ),
        cachedAt: DateTime.parse('2026-08-25T09:00:00Z'),
      );

      final restored = AccountAccessState.fromCacheJson(original.toCacheJson());

      expect(restored, isNotNull);
      expect(restored!.level, AccessLevel.grace);
      expect(restored.reason, AccessReason.paymentOverdue);
      expect(restored.enforced, isTrue);
      expect(restored.customerMessage, 'Regulariza antes del 30.');
      expect(restored.contactPhone, '809-000-0000');
      expect(restored.offlineMaxDays, 7);
      expect(restored.fromCache, isTrue);
      expect(
        restored.cachedAt.toUtc(),
        DateTime.parse('2026-08-25T09:00:00Z'),
        reason: 'la marca local es la que mide la antigüedad',
      );
    });

    test('un snapshot corrupto se ignora en vez de tumbar el arranque', () {
      expect(AccountAccessState.fromCacheJson('{no es json'), isNull);
      expect(AccountAccessState.fromCacheJson('{}'), isNull);
      expect(AccountAccessState.fromCacheJson('{"payload":{}}'), isNull);
    });
  });

  group('mapeo de motivos', () {
    test('todos los motivos del servidor tienen ida y vuelta', () {
      for (final r in AccessReason.values) {
        expect(AccessReason.fromWire(r.wire), r, reason: r.name);
        expect(r.title, isNotEmpty, reason: r.name);
      }
    });

    test('un motivo desconocido no rompe nada', () {
      expect(AccessReason.fromWire('motivo_del_futuro'), AccessReason.none);
      expect(AccessLevel.fromWire('estado_del_futuro'), AccessLevel.ok);
    });
  });

  group('ritmo del poll', () {
    Duration forState(String state, {bool enforced = true}) {
      return AccountAccessRepository.pollIntervalFor(
        AccountAccessState.fromRpc(_rpc(state: state, enforced: enforced)),
      );
    }

    test('un negocio sano sin enforcement se consulta poco', () {
      expect(forState('ok', enforced: false), const Duration(minutes: 30));
    });

    test('sano con enforcement se consulta a ritmo medio', () {
      expect(forState('ok'), const Duration(minutes: 10));
    });

    test('con algo en juego se aprieta el paso', () {
      for (final s in ['warning', 'grace', 'locked']) {
        expect(forState(s), const Duration(minutes: 2), reason: s);
      }
    });

    test('sin estado todavía usa el intervalo base', () {
      expect(
        AccountAccessRepository.pollIntervalFor(null),
        const Duration(minutes: 3),
      );
    });
  });
}
