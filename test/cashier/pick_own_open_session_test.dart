import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';

/// Precedencia de "cual de las cajas abiertas de la registradora es la mia".
///
/// Es lo que permite que dos cajeras operen a la vez: cada una ve SU caja y
/// puede abrir/cerrar/arquear sin tocar la de la otra. Devolver null es la
/// senal de "no tengo caja" que habilita el boton "Abrir caja".
void main() {
  Map<String, dynamic> session(
    String id, {
    String? userId,
    String? deviceId,
  }) =>
      {
        'id': id,
        'user_id': userId,
        'device_id': deviceId,
        'status': 'open',
      };

  group('pickOwnOpenSession', () {
    test('sin cajas abiertas devuelve null', () {
      expect(
        CashierRepository.pickOwnOpenSession(
          const [],
          userId: 'u1',
          deviceId: 'd1',
        ),
        isNull,
      );
    });

    test('prefiere la caja del usuario aunque otra sea mas reciente', () {
      final abiertas = [
        session('s-otra', userId: 'u2', deviceId: 'd2'),
        session('s-mia', userId: 'u1', deviceId: 'd1'),
      ];

      expect(
        CashierRepository.pickOwnOpenSession(
          abiertas,
          userId: 'u1',
          deviceId: 'd1',
        )?['id'],
        's-mia',
      );
    });

    test('la caja de otra cajera NO se adopta: devuelve null', () {
      // El caso que bloqueaba la segunda caja: la primera cajera tiene la
      // suya abierta en otro equipo y la segunda veia "Caja abierta".
      final abiertas = [session('s-de-ella', userId: 'u2', deviceId: 'd2')];

      expect(
        CashierRepository.pickOwnOpenSession(
          abiertas,
          userId: 'u1',
          deviceId: 'd1',
        ),
        isNull,
      );
    });

    test('sin caja propia hereda la abierta desde ESTE equipo', () {
      // Cambio de turno en la misma estacion: la caja quedo abierta a nombre
      // del turno anterior y quien entra debe poder cerrarla (con PIN de
      // supervisor, gate que ya vive en cashier_view).
      final abiertas = [session('s-turno-previo', userId: 'u9', deviceId: 'd1')];

      expect(
        CashierRepository.pickOwnOpenSession(
          abiertas,
          userId: 'u1',
          deviceId: 'd1',
        )?['id'],
        's-turno-previo',
      );
    });

    test('el usuario gana sobre el dispositivo', () {
      final abiertas = [
        session('s-este-equipo', userId: 'u9', deviceId: 'd1'),
        session('s-mia-otro-equipo', userId: 'u1', deviceId: 'd7'),
      ];

      expect(
        CashierRepository.pickOwnOpenSession(
          abiertas,
          userId: 'u1',
          deviceId: 'd1',
        )?['id'],
        's-mia-otro-equipo',
      );
    });

    test('sin device_id en la BD sigue resolviendo por usuario', () {
      // BD sin la migracion 20260401_0002: las filas no traen device_id.
      final abiertas = [
        {'id': 's-mia', 'user_id': 'u1', 'status': 'open'},
      ];

      expect(
        CashierRepository.pickOwnOpenSession(
          abiertas,
          userId: 'u1',
          deviceId: 'd1',
        )?['id'],
        's-mia',
      );
    });

    test('sin usuario ni dispositivo no adopta nada', () {
      final abiertas = [session('s-ajena', userId: 'u2', deviceId: 'd2')];

      expect(CashierRepository.pickOwnOpenSession(abiertas), isNull);
    });
  });
}
