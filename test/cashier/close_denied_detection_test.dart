import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';

/// El candado server-side del cierre (`fn_close_cash_session`) llega como
/// texto libre dentro de un PostgrestException. Si no lo reconocemos, el
/// cajero se queda con "Error de base de datos: CLOSE_DENIED: only the
/// session owner..." DESPUÉS de haber firmado el conteo a ciegas, sin
/// ninguna salida. Este matcher es el que dispara el reintento por
/// force-close.
void main() {
  group('CashierRepository.isCloseDeniedError', () {
    test('reconoce el mensaje de la migración 20260401_0002', () {
      expect(
        CashierRepository.isCloseDeniedError(
          'CLOSE_DENIED: only the session owner or a business admin/owner '
          'can close this session',
        ),
        isTrue,
      );
    });

    test('reconoce el mensaje nuevo (incluye manager)', () {
      expect(
        CashierRepository.isCloseDeniedError(
          'CLOSE_DENIED: only the session owner or a business '
          'admin/owner/manager can close this session',
        ),
        isTrue,
      );
    });

    test('no confunde otros errores de negocio del mismo RPC', () {
      expect(CashierRepository.isCloseDeniedError('OPEN_TABLES_EXIST'), isFalse);
      expect(CashierRepository.isCloseDeniedError('SESSION_NOT_FOUND'), isFalse);
      expect(
        CashierRepository.isCloseDeniedError('SESSION_ALREADY_CLOSED'),
        isFalse,
      );
      expect(CashierRepository.isCloseDeniedError(''), isFalse);
    });
  });
}
