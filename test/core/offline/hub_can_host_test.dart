// Quién puede pedir ser la caja principal (Hub). La concesión es permanente y
// la toma el primero que la pida: tiene que ser el equipo con la CAJA ABIERTA.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/services/session/session_controller.dart';

const _biz = 'biz-1';
const _device = 'dev-caja';

Map<String, dynamic> _open({String device = _device, String? business}) => {
  'id': 's-1',
  'status': 'open',
  'closed_at': null,
  'device_id': device,
  'business_id': ?business,
};

bool _can(
  PosRole? role,
  Map<String, dynamic>? session, {
  String? cashierBusiness = _biz,
}) => canHostHub(
  role: role,
  cashSession: session,
  cashierBusinessId: cashierBusiness,
  businessId: _biz,
  deviceId: _device,
);

void main() {
  test('cajero, admin y supervisor con la caja abierta EN este equipo', () {
    for (final role in [
      PosRole.cajero,
      PosRole.administrador,
      PosRole.supervisor,
    ]) {
      expect(_can(role, _open()), isTrue, reason: '$role');
    }
  });

  test('la sesión del servidor no trae business_id: vale el de la caja', () {
    // Antes esto daba false y el dueño en caja nunca llegaba a ser el Hub.
    expect(_can(PosRole.administrador, _open()), isTrue);
    expect(
      _can(PosRole.administrador, _open(), cashierBusiness: 'otro'),
      isFalse,
    );
  });

  test('un cajero SIN caja abierta no la pide (PC de mesero con usuario de '
      'cajero)', () {
    expect(_can(PosRole.cajero, null), isFalse);
  });

  test('la caja abierta en OTRO equipo no cuenta', () {
    expect(_can(PosRole.cajero, _open(device: 'dev-mesero')), isFalse);
  });

  test('caja cerrada o de otro negocio no cuenta', () {
    expect(_can(PosRole.cajero, {..._open(), 'status': 'closed'}), isFalse);
    expect(
      _can(PosRole.cajero, {..._open(), 'closed_at': '2026-09-30'}),
      isFalse,
    );
    expect(_can(PosRole.cajero, _open(business: 'otro')), isFalse);
  });

  test('mesero, cocina y delivery nunca', () {
    for (final role in [PosRole.mesero, PosRole.cocina, PosRole.delivery]) {
      expect(_can(role, _open()), isFalse, reason: '$role');
    }
    expect(_can(null, _open()), isFalse);
  });
}
