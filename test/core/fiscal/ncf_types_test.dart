import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/fiscal/ncf_types.dart';

/// Distinguir e-CF de NCF de papel decide si el cobro consulta a la DGII o
/// no, y por lo tanto si la UI promete una espera que existe.
///
/// El caso que motivó estos tests: `SalesViewModel._normalizeFiscalTypeValue`
/// le quita la letra al tipo antes de guardarlo, así que al modal de cobro le
/// llega '32' y no 'E32'. Un `startsWith('E')` sobre eso da false, el panel
/// dejaba de listar la etapa de DGII y se pintaba entero en gris mientras el
/// botón decía "Consultando con la DGII".
void main() {
  group('isElectronicNcf', () {
    test('reconoce la serie electrónica venga con letra o pelada', () {
      for (final code in ['E31', 'E32', '31', '32', '41', '46']) {
        expect(isElectronicNcf(code), isTrue, reason: code);
      }
    });

    test('reconoce la serie de papel venga con letra o pelada', () {
      for (final code in ['B01', 'B02', '01', '02', '11', '16']) {
        expect(isElectronicNcf(code), isFalse, reason: code);
      }
    });

    test('null, vacío y basura no se asumen electrónicos', () {
      // Asumir e-CF por defecto haría que la UI prometa una consulta a la
      // DGII que nunca ocurre, y el paso se quedaría girando.
      expect(isElectronicNcf(null), isFalse);
      expect(isElectronicNcf('   '), isFalse);
      expect(isElectronicNcf('99'), isFalse);
    });

    test('tolera espacios y minúsculas', () {
      expect(isElectronicNcf(' e32 '), isTrue);
      expect(isElectronicNcf(' b02 '), isFalse);
    });
  });

  group('fullNcfCode', () {
    test('repone la letra que el módulo de ventas le quita', () {
      expect(fullNcfCode('32'), 'E32');
      expect(fullNcfCode('02'), 'B02');
      expect(fullNcfCode('31'), 'E31');
      expect(fullNcfCode('01'), 'B01');
    });

    test('respeta el código que ya viene completo', () {
      expect(fullNcfCode('E31'), 'E31');
      expect(fullNcfCode('B02'), 'B02');
    });

    test('un sufijo desconocido se devuelve tal cual, sin inventar serie', () {
      // Mejor mostrar '99' que afirmar 'B99' o 'E99': si DGII agrega un
      // código, preferimos que se note que no lo conocemos.
      expect(fullNcfCode('99'), '99');
    });

    test('sin código no hay chip', () {
      expect(fullNcfCode(null), isNull);
      expect(fullNcfCode('  '), isNull);
    });
  });
}
