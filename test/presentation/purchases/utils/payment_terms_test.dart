import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/purchases/utils/payment_terms.dart';

void main() {
  group('PaymentTerms.resolve — número explícito del proveedor', () {
    test('payment_terms_days = 30 preselecciona 30 y es DATO', () {
      final s = PaymentTerms.resolve(days: 30, freeText: '30 días');
      expect(s.days, 30);
      expect(s.fromNumber, isTrue);
      expect(s.text, '30 días');
    });

    test('el número manda sobre el texto', () {
      final s = PaymentTerms.resolve(days: 45, freeText: '30 días');
      expect(s.days, 45);
      expect(s.fromNumber, isTrue);
    });

    // En la BD viva la columna es integer NOT NULL default 0 y los 120
    // proveedores existentes traen 0: ahí 0 significa "sin configurar", no
    // "pago a 0 días". Tratarlo como plazo llenaría de vencimientos falsos.
    test('0 es «sin configurar» y cae al texto libre, no preselecciona', () {
      expect(PaymentTerms.resolve(days: 0).days, isNull);
      expect(PaymentTerms.resolve(days: 0, freeText: '45 días').days, 45);
      expect(
        PaymentTerms.resolve(days: 0, freeText: '50% anticipo').days,
        isNull,
      );
    });

    test('un número fuera de rango no se usa', () {
      expect(PaymentTerms.resolve(days: -5).days, isNull);
      expect(PaymentTerms.resolve(days: 400).days, isNull);
    });
  });

  group('PaymentTerms.resolve — solo texto libre', () {
    test('«30 días» preselecciona 30 como SUGERENCIA', () {
      final s = PaymentTerms.resolve(freeText: '30 días');
      expect(s.days, 30);
      expect(s.fromNumber, isFalse);
    });

    test('«Neto 30» también es inequívoco', () {
      expect(PaymentTerms.resolve(freeText: 'Neto 30').days, 30);
    });

    test('«50% anticipo» NO preselecciona nada', () {
      final s = PaymentTerms.resolve(freeText: '50% anticipo');
      expect(s.days, isNull);
      expect(s.text, '50% anticipo');
    });

    test('«2/10 neto 30» es ambiguo: no preselecciona', () {
      expect(PaymentTerms.resolve(freeText: '2/10 neto 30').days, isNull);
    });

    test('«contado» no trae número: no preselecciona', () {
      final s = PaymentTerms.resolve(freeText: 'contado');
      expect(s.days, isNull);
      expect(s.hasText, isTrue);
    });

    test('sin condiciones: ninguna ficha activa y sin texto', () {
      final s = PaymentTerms.resolve();
      expect(s.days, isNull);
      expect(s.hasSuggestion, isFalse);
      expect(s.hasText, isFalse);
    });
  });

  test('las fichas ofrecidas son 15, 30, 45 y 60', () {
    expect(PaymentTerms.offeredDays, [15, 30, 45, 60]);
  });
}
