import 'package:equatable/equatable.dart';

class DenominationCount extends Equatable {
  final int value;
  final String label;
  final int count;

  const DenominationCount({
    required this.value,
    required this.label,
    this.count = 0,
  });

  int get subtotal => value * count;

  DenominationCount copyWith({int? count}) {
    return DenominationCount(value: value, label: label, count: count ?? this.count);
  }

  @override
  List<Object?> get props => [value, label, count];
}

class CashCloseInput extends Equatable {
  final int expectedCash;
  final int expectedCard;
  final int expectedTransfer;
  final int totalSales;
  final int transactionCount;
  final String cashierName;
  final String businessName;

  const CashCloseInput({
    required this.expectedCash,
    required this.expectedCard,
    required this.expectedTransfer,
    required this.totalSales,
    required this.transactionCount,
    this.cashierName = 'Admin',
    this.businessName = 'MangoPOS Restaurant',
  });

  int get expectedTotal => expectedCash + expectedCard + expectedTransfer;

  @override
  List<Object?> get props => [
        expectedCash,
        expectedCard,
        expectedTransfer,
        totalSales,
        transactionCount,
        cashierName,
        businessName,
      ];
}

class CashCloseResult extends Equatable {
  final int totalCounted;
  final int numericCard;
  final int numericTransfer;
  final int totalReported;
  final int expectedTotal;
  final int difference;

  const CashCloseResult({
    required this.totalCounted,
    required this.numericCard,
    required this.numericTransfer,
    required this.totalReported,
    required this.expectedTotal,
    required this.difference,
  });

  bool get isBalanced => difference == 0;
  bool get hasSurplus => difference > 0;
  bool get hasShortage => difference < 0;

  @override
  List<Object?> get props => [
        totalCounted,
        numericCard,
        numericTransfer,
        totalReported,
        expectedTotal,
        difference,
      ];
}

class CashCloseCalculator {
  static int parseAmount(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return 0;
    return int.tryParse(digits) ?? 0;
  }

  static int calculateCashCounted(List<DenominationCount> denominations) {
    return denominations.fold<int>(0, (sum, d) => sum + d.subtotal);
  }

  static CashCloseResult calculate({
    required List<DenominationCount> denominations,
    required String cardInput,
    required String transferInput,
    required CashCloseInput input,
  }) {
    final totalCounted = calculateCashCounted(denominations);
    final numericCard = parseAmount(cardInput);
    final numericTransfer = parseAmount(transferInput);
    final totalReported = totalCounted + numericCard + numericTransfer;
    final expectedTotal = input.expectedTotal;
    final difference = totalReported - expectedTotal;

    return CashCloseResult(
      totalCounted: totalCounted,
      numericCard: numericCard,
      numericTransfer: numericTransfer,
      totalReported: totalReported,
      expectedTotal: expectedTotal,
      difference: difference,
    );
  }
}

