import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';

void main() {
  group('CashCloseCalculator', () {
    const input = CashCloseInput(
      expectedCash: 28500,
      expectedCard: 12500,
      expectedTransfer: 4200,
      totalSales: 45200,
      transactionCount: 28,
    );

    test('calcula totalCounted por denominacion', () {
      final denominations = [
        const DenominationCount(value: 2000, label: 'RD\$ 2000', count: 1),
        const DenominationCount(value: 500, label: 'RD\$ 500', count: 3),
        const DenominationCount(value: 100, label: 'RD\$ 100', count: 2),
      ];

      final total = CashCloseCalculator.calculateCashCounted(denominations);
      expect(total, 3700);
    });

    test('aplica formula completa de cierre', () {
      final result = CashCloseCalculator.calculate(
        denominations: const [
          DenominationCount(value: 1000, label: 'RD\$ 1000', count: 30),
        ],
        // Sin separador de miles A PROPÓSITO: ninguna de las dos UIs puede
        // producirlo. El teclado del cierre a ciegas solo agrega dígitos, '.',
        // '00' y borrado (blind_cash_close_viewmodel.appendNumpad), y el wizard
        // detallado convierte la coma en punto y exige `^\d*\.?\d{0,2}$`
        // (_DecimalMoneyInputFormatter). Este test pasaba '12,500' y esperaba
        // 12500; llevaba tres semanas en rojo por eso.
        cardInput: '12500',
        transferInput: '4200',
        input: input,
      );

      expect(result.totalCounted, 30000);
      expect(result.numericCard, 12500);
      expect(result.numericTransfer, 4200);
      expect(result.totalReported, 46700);
      expect(result.expectedTotal, 45200);
      expect(result.difference, 1500);
    });

    // Guardarraíl: que nadie "arregle" parseAmount para aceptar separador de
    // miles. En República Dominicana la coma es separador DECIMAL, así que
    // leer '12,5' como 125 (o '12,500' como doce mil quinientos) descuadraría
    // el cierre por miles de pesos en el sentido equivocado. Si algún día hay
    // que aceptar comas, se decide en el FORMATTER —que ya las normaliza a
    // punto— y no aquí a la adivina.
    test('una cadena ambigua con coma NO se interpreta como miles', () {
      expect(CashCloseCalculator.parseAmount('12,500'), 0);
      expect(CashCloseCalculator.parseAmount('12,5'), 0);
    });

    test('acepta lo que las UIs sí producen', () {
      expect(CashCloseCalculator.parseAmount('12500'), 12500);
      expect(CashCloseCalculator.parseAmount('12500.50'), 12500.50);
      expect(CashCloseCalculator.parseAmount('0.'), 0);
    });

    test('parsea vacio como 0', () {
      final result = CashCloseCalculator.calculate(
        denominations: const [],
        cardInput: '',
        transferInput: '',
        input: input,
      );

      expect(result.numericCard, 0);
      expect(result.numericTransfer, 0);
      expect(result.totalCounted, 0);
      expect(result.totalReported, 0);
      expect(result.difference, -45200);
    });
  });
}
