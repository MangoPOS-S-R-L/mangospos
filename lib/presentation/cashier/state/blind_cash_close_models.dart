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
  final int startAmount;

  const CashCloseInput({
    required this.expectedCash,
    required this.expectedCard,
    required this.expectedTransfer,
    required this.totalSales,
    required this.transactionCount,
    this.cashierName = 'Admin',
    this.businessName = 'MangoPOS Restaurant',
    this.startAmount = 0,
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
    startAmount,
  ];
}

class CashCloseResult extends Equatable {
  final int totalCounted;
  final double numericCard;
  final double numericTransfer;
  final double totalReported;
  final int expectedTotal;
  final int cashDifference;
  final double cardDifference;
  final double transferDifference;
  final double totalDifference;

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

  double get difference => totalDifference;
  bool get isBalanced =>
      cashDifference == 0 &&
      cardDifference.abs() < 0.01 &&
      transferDifference.abs() < 0.01 &&
      totalDifference.abs() < 0.01;
  bool get hasSurplus => totalDifference > 0.01;
  bool get hasShortage => totalDifference < -0.01;

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
  static double parseAmount(String raw) {
    if (raw.isEmpty) return 0;
    return double.tryParse(raw) ?? 0;
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
