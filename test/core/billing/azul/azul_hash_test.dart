// PRD-Azul-Subscriptions §6.3 — Golden test del AuthHash + variantes.
//
// Golden source: archivo "Ejemplo Calculo Hash SALE.TXT" provisto por Azul.
// Hash esperado validado byte-exacto en Python (UTF-8, HMAC-SHA512).

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/billing/azul/azul_hash.dart';

void main() {
  group('AzulHash.compute — golden test §6.3', () {
    // AuthKey exacta del ejemplo de Azul (no rotada porque solo es test data).
    const goldenAuthKey =
        'asdhakjshdkjasdasmndajksdkjaskldga8odya9d8yoasyd98asdyaisdhoaisyd0a8sydoashd8oasydoiahdpiashd09ayusidhaos8dy0a8dya08syd0a8ssdsax';

    const expectedHash =
        '6662f1e52260cf845a848845e6769ece7ef173c2809ea215f1fc8907442a21f3'
        '95bdfbb8422eb4d6ce8673eb6961beb730d97842e8030668516beba717ffff5b';

    test('produce hash byte-exacto contra el ejemplo de Azul', () {
      const fields = AzulPaymentPageFields(
        merchantId: '39038540035',
        merchantName: 'Prueba AZUL',
        merchantType: 'ECommerce',
        currencyCode: r'$',
        orderNumber: '001',
        amount: '10000',
        itbis: '000',
        approvedUrl: 'https://google.com',
        declinedUrl: 'https://google.com',
        cancelUrl: 'https://google.com',
        // custom fields quedan en sus defaults: useCustomField1/2='0', labels/values=''
      );

      final hash = AzulHash.compute(
        orderedFields: fields.toOrderedFields(),
        authKey: goldenAuthKey,
      );

      expect(hash, equals(expectedHash));
      expect(hash.length, equals(128));
      expect(hash, equals(hash.toLowerCase()));
    });

    test('hash es determinístico — dos invocaciones con mismos inputs', () {
      const fields = AzulPaymentPageFields(
        merchantId: '39038540035',
        merchantName: 'Prueba AZUL',
        merchantType: 'ECommerce',
        currencyCode: r'$',
        orderNumber: '001',
        amount: '10000',
        itbis: '000',
        approvedUrl: 'https://google.com',
        declinedUrl: 'https://google.com',
        cancelUrl: 'https://google.com',
      );

      final h1 = AzulHash.compute(
        orderedFields: fields.toOrderedFields(),
        authKey: goldenAuthKey,
      );
      final h2 = AzulHash.compute(
        orderedFields: fields.toOrderedFields(),
        authKey: goldenAuthKey,
      );

      expect(h1, equals(h2));
    });
  });

  group('AzulHash.compute — variantes (PRD F0 definición de hecho)', () {
    const k = 'auth-key-de-prueba-123';

    test('campos vacíos al inicio, medio y fin no rompen el hash', () {
      final hash = AzulHash.compute(
        orderedFields: const ['', 'medio', '', 'final', ''],
        authKey: k,
      );

      // Resultado conocido: HMAC-SHA512('mediofinal' + k, key=k) en UTF-8.
      // Lo verificamos contra el algoritmo aplicado a la string concatenada
      // equivalente (ambas formas deben coincidir).
      final equivalent = AzulHash.compute(
        orderedFields: const ['mediofinal'],
        authKey: k,
      );
      expect(hash, equals(equivalent));
      expect(hash.length, equals(128));
    });

    test('todos los campos vacíos producen un hash válido (solo AuthKey)', () {
      final hash = AzulHash.compute(
        orderedFields: const ['', '', '', ''],
        authKey: k,
      );
      expect(hash.length, equals(128));
      expect(RegExp(r'^[0-9a-f]{128}$').hasMatch(hash), isTrue);
    });

    test('caracteres con acentos (UTF-8 multi-byte) producen hash distinto a sin acento', () {
      final conAcento = AzulHash.compute(
        orderedFields: const ['Restauración'],
        authKey: k,
      );
      final sinAcento = AzulHash.compute(
        orderedFields: const ['Restauracion'],
        authKey: k,
      );
      expect(conAcento, isNot(equals(sinAcento)));
      expect(conAcento.length, equals(128));
    });

    test('símbolos especiales (\$, &, ñ, ü) se hashean sin escapado', () {
      final hash = AzulHash.compute(
        orderedFields: const [r'$', '&', 'ñ', 'ü', 'café & té'],
        authKey: k,
      );
      expect(hash.length, equals(128));
      expect(RegExp(r'^[0-9a-f]{128}$').hasMatch(hash), isTrue);
    });

    test('AuthKey con caracteres especiales produce hash válido', () {
      final hash = AzulHash.compute(
        orderedFields: const ['campo'],
        authKey: r'$ecret&Key#con!símbolos™',
      );
      expect(hash.length, equals(128));
      expect(RegExp(r'^[0-9a-f]{128}$').hasMatch(hash), isTrue);
    });

    test('cambiar UN solo char en cualquier campo cambia el hash (avalanche)', () {
      final base = AzulHash.compute(
        orderedFields: const ['a', 'b', 'c'],
        authKey: k,
      );
      final cambioInicio = AzulHash.compute(
        orderedFields: const ['A', 'b', 'c'],
        authKey: k,
      );
      final cambioMedio = AzulHash.compute(
        orderedFields: const ['a', 'B', 'c'],
        authKey: k,
      );
      final cambioFin = AzulHash.compute(
        orderedFields: const ['a', 'b', 'C'],
        authKey: k,
      );

      expect(base, isNot(equals(cambioInicio)));
      expect(base, isNot(equals(cambioMedio)));
      expect(base, isNot(equals(cambioFin)));
      expect(cambioInicio, isNot(equals(cambioMedio)));
    });

    test('cambiar la AuthKey con todo lo demás igual cambia el hash', () {
      final h1 = AzulHash.compute(
        orderedFields: const ['campo1', 'campo2'],
        authKey: 'key-uno',
      );
      final h2 = AzulHash.compute(
        orderedFields: const ['campo1', 'campo2'],
        authKey: 'key-dos',
      );
      expect(h1, isNot(equals(h2)));
    });

    test('orden de campos importa — concatenación sin separadores', () {
      // Demuestra por qué el orden es crítico: ['ab','c'] y ['a','bc'] dan el
      // mismo hash (porque concatenan a 'abc'), pero ['ab','c'] y ['ac','b']
      // dan hashes distintos. El backend NUNCA debe reordenar.
      final orden1 = AzulHash.compute(
        orderedFields: const ['ab', 'c'],
        authKey: k,
      );
      final orden2 = AzulHash.compute(
        orderedFields: const ['a', 'bc'],
        authKey: k,
      );
      final orden3 = AzulHash.compute(
        orderedFields: const ['ac', 'b'],
        authKey: k,
      );
      expect(orden1, equals(orden2)); // misma concatenación → mismo hash
      expect(orden1, isNot(equals(orden3))); // distinta concatenación
    });

    test('respuesta de Azul: campos ordenados según §6.2 producen 128 hex', () {
      const resp = AzulResponseFields(
        orderNumber: '001',
        amount: '10000',
        authorizationCode: 'OK1234',
        dateTime: '20260526120000',
        responseCode: 'ISO8583',
        isoCode: '00',
        responseMessage: 'APROBADA',
        errorDescription: '',
        rrn: '999888777',
      );
      final hash = AzulHash.compute(
        orderedFields: resp.toOrderedFields(),
        authKey: k,
      );
      expect(hash.length, equals(128));
    });
  });

  group('AzulHash.constantTimeEquals', () {
    test('hashes idénticos → true', () {
      final h = 'deadbeef' * 16; // 128 chars
      expect(AzulHash.constantTimeEquals(h, h), isTrue);
    });

    test('hashes distintos del mismo largo → false', () {
      final a = 'a' * 128;
      final b = 'b' * 128;
      expect(AzulHash.constantTimeEquals(a, b), isFalse);
    });

    test('largos distintos → false sin lanzar', () {
      expect(AzulHash.constantTimeEquals('abc', 'abcd'), isFalse);
      expect(AzulHash.constantTimeEquals('', 'a'), isFalse);
    });

    test('un solo byte distinto → false (caso típico de hash falsificado)', () {
      final a = 'deadbeef' * 16;
      final b = a.replaceFirst('d', 'e'); // primer char distinto, mismo largo
      expect(AzulHash.constantTimeEquals(a, b), isFalse);
    });

    test('strings vacíos iguales → true (caso borde)', () {
      expect(AzulHash.constantTimeEquals('', ''), isTrue);
    });
  });
}
