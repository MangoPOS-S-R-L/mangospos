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
        cardInput: '12,500',
        transferInput: '4,200',
        input: input,
      );

      expect(result.totalCounted, 30000);
      expect(result.numericCard, 12500);
      expect(result.numericTransfer, 4200);
      expect(result.totalReported, 46700);
      expect(result.expectedTotal, 45200);
      expect(result.difference, 1500);
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
