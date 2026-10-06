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
    String? registerId,
  }) =>
      {
        'id': id,
        'user_id': userId,
        'device_id': deviceId,
        'cash_register_id': registerId,
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

  group('pickOwnOpenSession en todo el negocio', () {
    test('mi caja en OTRA registradora es mia: no "no tienes caja"', () {
      // El bug reportado 2026-10-05: el equipo estaba atado a otra
      // registradora, la pantalla decia "no tienes caja" y al abrir el server
      // respondia "ya tienes una caja abierta".
      final abiertas = [
        session('s-ajena', userId: 'u2', deviceId: 'd2', registerId: 'r1'),
        session('s-mia', userId: 'u1', deviceId: 'd-viejo', registerId: 'r2'),
      ];

      expect(
        CashierRepository.pickOwnOpenSession(
          abiertas,
          userId: 'u1',
          deviceId: 'd-nuevo',
          registerId: 'r1',
        )?['id'],
        's-mia',
      );
    });

    test('dueño con 2 cajas: gana la abierta desde ESTE equipo', () {
      final abiertas = [
        session('s-otra-pc', userId: 'u1', deviceId: 'd2', registerId: 'r1'),
        session('s-esta-pc', userId: 'u1', deviceId: 'd1', registerId: 'r2'),
      ];

      expect(
        CashierRepository.pickOwnOpenSession(
          abiertas,
          userId: 'u1',
          deviceId: 'd1',
          registerId: 'r1',
        )?['id'],
        's-esta-pc',
      );
    });

    test('sin caja en este equipo: la de la registradora del equipo', () {
      final abiertas = [
        session('s-otra-reg', userId: 'u1', deviceId: 'd2', registerId: 'r2'),
        session('s-esta-reg', userId: 'u1', deviceId: 'd3', registerId: 'r1'),
      ];

      expect(
        CashierRepository.pickOwnOpenSession(
          abiertas,
          userId: 'u1',
          deviceId: 'd1',
          registerId: 'r1',
        )?['id'],
        's-esta-reg',
      );
    });

    test('multi caja: la caja de otro cajero en otro equipo NO se adopta', () {
      final abiertas = [
        session('s-de-ella', userId: 'u2', deviceId: 'd2', registerId: 'r1'),
      ];

      expect(
        CashierRepository.pickOwnOpenSession(
          abiertas,
          userId: 'u1',
          deviceId: 'd1',
          registerId: 'r1',
        ),
        isNull,
      );
    });
  });

  group('pickSharedOpenSession (modo 1 sola caja)', () {
    test('sin cajas abiertas devuelve null', () {
      expect(
        CashierRepository.pickSharedOpenSession(const [], registerId: 'r1'),
        isNull,
      );
    });

    test('la caja de otro usuario se comparte', () {
      final abiertas = [
        session('s-del-cajero', userId: 'u2', deviceId: 'd2', registerId: 'r1'),
      ];

      expect(
        CashierRepository.pickSharedOpenSession(
          abiertas,
          registerId: 'r1',
        )?['id'],
        's-del-cajero',
      );
    });

    test('prefiere la de la registradora del equipo', () {
      final abiertas = [
        session('s-reciente-otra-reg', userId: 'u2', registerId: 'r2'),
        session('s-esta-reg', userId: 'u3', registerId: 'r1'),
      ];

      expect(
        CashierRepository.pickSharedOpenSession(
          abiertas,
          registerId: 'r1',
        )?['id'],
        's-esta-reg',
      );
    });

    test('si la registradora del equipo no tiene, la mas reciente', () {
      final abiertas = [
        session('s-reciente', userId: 'u2', registerId: 'r2'),
        session('s-vieja', userId: 'u3', registerId: 'r3'),
      ];

      expect(
        CashierRepository.pickSharedOpenSession(
          abiertas,
          registerId: 'r1',
        )?['id'],
        's-reciente',
      );
    });
  });

  group('resolveDeviceCash: la caja es del equipo donde se abrió', () {
    ({Map<String, dynamic>? operable, Map<String, dynamic>? elsewhere}) resolve(
      List<Map<String, dynamic>> open, {
      required String userId,
      required String deviceId,
      bool single = true,
      bool admin = false,
    }) => CashierRepository.resolveDeviceCash(
      open,
      userId: userId,
      deviceId: deviceId,
      registerId: 'r1',
      singleMode: single,
      canOperateAnyDevice: admin,
    );

    test('cajera en OTRO equipo: su caja queda "en otro equipo", no operable', () {
      final r = resolve(
        [session('s-mia', userId: 'u1', deviceId: 'd-caja', registerId: 'r1')],
        userId: 'u1',
        deviceId: 'd-otra-pc',
      );
      expect(r.operable, isNull);
      expect(r.elsewhere?['id'], 's-mia');
    });

    test('cajera en SU equipo: opera su caja', () {
      final r = resolve(
        [session('s-mia', userId: 'u1', deviceId: 'd-caja', registerId: 'r1')],
        userId: 'u1',
        deviceId: 'd-caja',
      );
      expect(r.operable?['id'], 's-mia');
      expect(r.elsewhere, isNull);
    });

    test('relevo en el equipo de la caja: opera la caja de ese equipo', () {
      final r = resolve(
        [session('s-turno', userId: 'u9', deviceId: 'd-caja', registerId: 'r1')],
        userId: 'u1',
        deviceId: 'd-caja',
        single: false,
      );
      expect(r.operable?['id'], 's-turno');
    });

    test('1 sola caja: la del negocio en otro equipo se informa', () {
      final r = resolve(
        [session('s-negocio', userId: 'u9', deviceId: 'd-caja', registerId: 'r1')],
        userId: 'u1',
        deviceId: 'd-tableta',
      );
      expect(r.operable, isNull);
      expect(r.elsewhere?['id'], 's-negocio');
    });

    test('multi caja: la de otra cajera en otro equipo no le toca', () {
      final r = resolve(
        [session('s-ajena', userId: 'u9', deviceId: 'd-caja', registerId: 'r1')],
        userId: 'u1',
        deviceId: 'd-otra-pc',
        single: false,
      );
      expect(r.operable, isNull);
      expect(r.elsewhere, isNull);
    });

    test('1 sola caja con 2 cajas ya abiertas: cada equipo sigue con la suya', () {
      // Negocios que llegan a "1 sola caja" con dos cajas abiertas (MAX,
      // Barra Payán): no se cierran ni se mezclan; cada equipo cobra con la
      // suya hasta que la cierren.
      final abiertas = [
        session('s-pc2', userId: 'u2', deviceId: 'd-pc2', registerId: 'r2'),
        session('s-pc1', userId: 'u1', deviceId: 'd-pc1', registerId: 'r1'),
      ];
      expect(
        resolve(abiertas, userId: 'u1', deviceId: 'd-pc1').operable?['id'],
        's-pc1',
      );
      expect(
        resolve(abiertas, userId: 'u2', deviceId: 'd-pc2').operable?['id'],
        's-pc2',
      );
    });

    test('admin opera su caja desde cualquier equipo', () {
      final r = resolve(
        [session('s-admin', userId: 'u1', deviceId: 'd-caja', registerId: 'r2')],
        userId: 'u1',
        deviceId: 'd-laptop',
        admin: true,
      );
      expect(r.operable?['id'], 's-admin');
      expect(r.elsewhere, isNull);
    });

    test('admin en 1 sola caja opera la del negocio desde cualquier equipo', () {
      final r = resolve(
        [session('s-negocio', userId: 'u9', deviceId: 'd-caja', registerId: 'r1')],
        userId: 'u1',
        deviceId: 'd-laptop',
        admin: true,
      );
      expect(r.operable?['id'], 's-negocio');
    });

    test('admin en multi caja sin caja propia puede abrir la suya', () {
      final r = resolve(
        [session('s-ajena', userId: 'u9', deviceId: 'd-caja', registerId: 'r1')],
        userId: 'u1',
        deviceId: 'd-laptop',
        single: false,
        admin: true,
      );
      expect(r.operable, isNull);
      expect(r.elsewhere, isNull);
    });
  });
}
