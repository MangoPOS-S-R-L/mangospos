import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/purchases/utils/ncf_format.dart';

void main() {
  group('NcfFormat.isValid', () {
    test('acepta un NCF de serie B con 8 de secuencia', () {
      expect(NcfFormat.isValid('B0100000284'), isTrue);
    });

    test('acepta un e-CF de serie E con 10 de secuencia', () {
      expect(NcfFormat.isValid('E310000000001'), isTrue);
    });

    test('normaliza minúsculas y espacios antes de validar', () {
      expect(NcfFormat.isValid(' b01 00000284 '), isTrue);
    });

    test('rechaza serie que no es B ni E', () {
      expect(NcfFormat.isValid('A0100000284'), isFalse);
    });

    test('rechaza secuencia corta o larga de más', () {
      expect(NcfFormat.isValid('B010000028'), isFalse); // 7 de secuencia
      expect(NcfFormat.isValid('B0100000000284'), isFalse); // 11 de secuencia
    });

    test('rechaza texto que no es un comprobante', () {
      expect(NcfFormat.isValid('FACT 1123'), isFalse);
      expect(NcfFormat.isValid('0004521'), isFalse);
    });
  });

  group('NcfFormat.validate', () {
    test('vacío es válido: el NCF es opcional', () {
      expect(NcfFormat.validate(''), isNull);
      expect(NcfFormat.validate('   '), isNull);
    });

    test('válido no devuelve motivo', () {
      expect(NcfFormat.validate('B0100000284'), isNull);
    });

    test('inválido devuelve el motivo escrito, con el valor leído', () {
      final reason = NcfFormat.validate('B01ABC');
      expect(reason, isNotNull);
      expect(reason, contains('B01ABC'));
    });
  });

  group('NcfFormat.normalize', () {
    test('sube a mayúsculas y quita espacios internos', () {
      expect(NcfFormat.normalize(' b01 0000 0284 '), 'B0100000284');
    });
  });
}
