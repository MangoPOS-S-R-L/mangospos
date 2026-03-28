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
    return DenominationCount(
      value: value,
      label: label,
      count: count ?? this.count,
    );
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
  int get expectedClosureAmount => expectedCash;

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
  final int cashDifference;
  final int cardDifference;
  final int transferDifference;
  final int totalDifference;

  const CashCloseResult({
    required this.totalCounted,
    required this.numericCard,
    required this.numericTransfer,
    required this.totalReported,
    required this.expectedTotal,
    required this.cashDifference,
    required this.cardDifference,
    required this.transferDifference,
    required this.totalDifference,
  });

  int get difference => totalDifference;
  bool get isBalanced =>
      cashDifference == 0 &&
      cardDifference == 0 &&
      transferDifference == 0 &&
      totalDifference == 0;
  bool get hasSurplus => totalDifference > 0;
  bool get hasShortage => totalDifference < 0;

  @override
  List<Object?> get props => [
    totalCounted,
    numericCard,
    numericTransfer,
    totalReported,
    expectedTotal,
    cashDifference,
    cardDifference,
    transferDifference,
    totalDifference,
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
    final cashDifference = totalCounted - input.expectedCash;
    final cardDifference = numericCard - input.expectedCard;
    final transferDifference = numericTransfer - input.expectedTransfer;
    final totalDifference = totalReported - expectedTotal;

    return CashCloseResult(
      totalCounted: totalCounted,
      numericCard: numericCard,
      numericTransfer: numericTransfer,
      totalReported: totalReported,
      expectedTotal: expectedTotal,
      cashDifference: cashDifference,
      cardDifference: cardDifference,
      transferDifference: transferDifference,
      totalDifference: totalDifference,
    );
  }
}
