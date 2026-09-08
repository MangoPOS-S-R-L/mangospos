import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/utils/order_number_utils.dart';

/// El número corto que sale en el ticket y en el historial.
///
/// Existe porque `order.id.substring(0, 8)` daba **el mismo texto para todas
/// las órdenes creadas offline**: sus ids son `local-order-<uuid>` y los
/// primeros 8 caracteres son siempre `local-or`. En el ticket se leía
/// `ORDEN: #LOCAL-OR` una y otra vez, y el cajero no podía distinguirlas.
void main() {
  group('orden del servidor (uuid)', () {
    // NO se puede cambiar: alteraría el número impreso en tickets ya emitidos
    // y rompería la correspondencia con lo que el cajero ve en el sistema.
    test('mantiene los primeros 8, como siempre', () {
      expect(
        shortOrderNumber('a1b2c3d4-e5f6-7890-abcd-ef1234567890'),
        'A1B2C3D4',
      );
    });

    test('dos órdenes distintas dan números distintos', () {
      final a = shortOrderNumber('a1b2c3d4-1111-1111-1111-111111111111');
      final b = shortOrderNumber('99887766-2222-2222-2222-222222222222');
      expect(a, isNot(b));
    });
  });

  group('orden creada offline', () {
    // EL BUG: sin esto las tres darían 'LOCAL-OR'.
    test('dos órdenes locales dan números DISTINTOS', () {
      final a = shortOrderNumber('local-order-a1b2c3d4-1111-1111-1111-aaaa1234');
      final b = shortOrderNumber('local-order-99887766-2222-2222-2222-bbbb5678');
      expect(a, isNot(b));
      expect(a, isNot(contains('LOCAL')));
      expect(b, isNot(contains('LOCAL')));
    });

    test('usa las últimas 4 del id, igual que el KDS', () {
      expect(
        shortOrderNumber('local-order-a1b2c3d4-1111-1111-1111-ef1234567890'),
        '7890',
      );
    });

    test('cubre los otros prefijos locales', () {
      expect(
        shortOrderNumber('local-session-aaaaaaaa-bbbb-cccc-dddd-eeee12345678'),
        '5678',
      );
      expect(
        shortOrderNumber('offline-op-aaaaaaaa-bbbb-cccc-dddd-eeee0000abcd'),
        'ABCD',
      );
      expect(
        shortOrderNumber('local-cash-session-aaaa-bbbb-cccc-dddd-eeeeffff'),
        'FFFF',
      );
    });
  });

  group('bordes que antes tumbaban la impresión', () {
    // Era un RangeError que reventaba `generateFiscalInvoice` a mitad de
    // imprimir: la factura no salía.
    test('un id más corto que 8 no truena', () {
      expect(shortOrderNumber('abc'), 'ABC');
      expect(shortOrderNumber('12345678'), '12345678');
    });

    test('vacío devuelve vacío', () {
      expect(shortOrderNumber(''), '');
      expect(shortOrderNumber('   '), '');
    });

    test('un id local sin resto no truena', () {
      expect(shortOrderNumber('local-order-'), 'LOCAL-ORDER-');
    });
  });
}
