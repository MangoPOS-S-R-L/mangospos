import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/sales/viewmodel/payment_split_viewmodel.dart';

/// Con qué caja se cobra una mesa.
///
/// El bug: la cajera abría la caja en su equipo y el cobro decía "Debes abrir
/// una caja antes de procesar el cobro". El modal mandaba el id de la caja que
/// había cuando se abrió por primera vez (a veces la de ayer, ya cerrada) y el
/// servidor la rechazaba con `CASH_SESSION_NOT_OPEN`.
void main() {
  Map<String, dynamic> session(
    String id, {
    String status = 'open',
    String? closedAt,
    String? userId,
    String? deviceId,
  }) => {
    'id': id,
    'status': status,
    'closed_at': closedAt,
    'user_id': userId,
    'device_id': deviceId,
  };

  group('openSessionIdOf: solo una caja abierta sirve para cobrar', () {
    test('caja abierta devuelve su id', () {
      expect(PaymentSplitViewModel.openSessionIdOf(session('s1')), 's1');
    });

    test('la caja de ayer, ya cerrada, no sirve', () {
      expect(
        PaymentSplitViewModel.openSessionIdOf(
          session('ayer', status: 'closed', closedAt: '2026-09-21T03:00:00Z'),
        ),
        isNull,
      );
    });

    test('status open pero con closed_at tampoco (fila a medio cerrar)', () {
      expect(
        PaymentSplitViewModel.openSessionIdOf(
          session('s1', closedAt: '2026-09-22T03:00:00Z'),
        ),
        isNull,
      );
    });

    test('sin sesión o sin id devuelve null', () {
      expect(PaymentSplitViewModel.openSessionIdOf(null), isNull);
      expect(PaymentSplitViewModel.openSessionIdOf(session('')), isNull);
    });
  });

  group('pickRegisterSessionForCharge: qué caja de la registradora', () {
    final cajera = session('de-la-cajera', userId: 'u-cajera', deviceId: 'd1');
    final otra = session('de-otra', userId: 'u-otra', deviceId: 'd2');

    test('sin cajas abiertas no hay con qué cobrar', () {
      expect(
        PaymentSplitViewModel.pickRegisterSessionForCharge(
          const [],
          userId: 'u-cajera',
          deviceId: 'd1',
        ),
        isNull,
      );
    });

    test('la mía primero, aunque haya otra más reciente', () {
      expect(
        PaymentSplitViewModel.pickRegisterSessionForCharge(
          [otra, cajera],
          userId: 'u-cajera',
          deviceId: 'd9',
        ),
        'de-la-cajera',
      );
    });

    test('sin caja propia, la abierta desde este equipo', () {
      expect(
        PaymentSplitViewModel.pickRegisterSessionForCharge(
          [otra, cajera],
          userId: 'u-dueno',
          deviceId: 'd1',
        ),
        'de-la-cajera',
      );
    });

    test('el mesero en su tableta cobra contra la más reciente', () {
      expect(
        PaymentSplitViewModel.pickRegisterSessionForCharge(
          [otra, cajera],
          userId: 'u-mesero',
          deviceId: 'd-tableta',
        ),
        'de-otra',
      );
    });
  });

  group('isCashSessionNotOpenError', () {
    test('reconoce el rechazo del RPC', () {
      expect(
        PaymentSplitViewModel.isCashSessionNotOpenError(
          Exception('PostgrestException(message: CASH_SESSION_NOT_OPEN)'),
        ),
        isTrue,
      );
    });

    test('otros errores no disparan el reintento', () {
      expect(
        PaymentSplitViewModel.isCashSessionNotOpenError(
          Exception('CHECK_ALREADY_CLOSED'),
        ),
        isFalse,
      );
      expect(
        PaymentSplitViewModel.isCashSessionNotOpenError(
          Exception('CASH_SESSION_REQUIRED'),
        ),
        isFalse,
      );
    });
  });
}
