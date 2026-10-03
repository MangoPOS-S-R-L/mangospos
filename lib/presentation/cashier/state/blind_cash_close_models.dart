import 'package:decimal/decimal.dart';
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

/// Dólares contados en la gaveta. Solo existe si el negocio activó la moneda
/// USD en Ajustes → Monedas. Se convierten a RD$ con la tasa del día y se
/// SUMAN al efectivo contado: el sistema registra en RD$ lo que se cobró en
/// dólares, así que el esperado de efectivo ya los incluye.
///
/// Se guarda dentro del JSONB `cash_count_blind.denominations` bajo la llave
/// `"usd"` (ver [toJson]); la reimpresión lo lee de vuelta con [fromJson].
class UsdCashCount extends Equatable {
  final String symbol;

  /// RD$ por 1 US$ usada en este cierre.
  final Decimal rate;

  /// La tasa de Ajustes al abrir el cierre. Queda en el JSONB para auditar
  /// si el cajero la cambió.
  final Decimal? configuredRate;

  /// `value` en dólares (100, 50, 20…).
  final List<DenominationCount> denominations;

  const UsdCashCount({
    required this.symbol,
    required this.rate,
    this.configuredRate,
    required this.denominations,
  });

  int get totalUsd => denominations.fold<int>(0, (sum, d) => sum + d.subtotal);

  /// Equivalente en RD$, redondeado al peso: el efectivo DOP no tiene
  /// centavos (ver `formatRD`). Sin tasa válida no convierte.
  int get totalDop {
    if (rate <= Decimal.zero) return 0;
    return (Decimal.fromInt(totalUsd) * rate).round().toBigInt().toInt();
  }

  bool get isEmpty => totalUsd == 0;

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'rate': double.parse(rate.toString()),
    if (configuredRate != null)
      'configured_rate': double.parse(configuredRate.toString()),
    'counts': {
      for (final d in denominations)
        if (d.count > 0) d.value.toString(): d.count,
    },
    'total_usd': totalUsd,
    'total_dop': totalDop,
  };

  /// Inverso de [toJson]. `null` si no hubo dólares en ese cierre.
  static UsdCashCount? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final rate = Decimal.tryParse(raw['rate']?.toString() ?? '');
    final counts = raw['counts'];
    if (rate == null || counts is! Map) return null;
    final list = <DenominationCount>[];
    counts.forEach((k, v) {
      final value = int.tryParse(k.toString());
      final count = v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0;
      if (value != null && count > 0) {
        list.add(DenominationCount(value: value, label: '', count: count));
      }
    });
    if (list.isEmpty) return null;
    list.sort((a, b) => b.value.compareTo(a.value));
    final symbol = raw['symbol']?.toString().trim() ?? '';
    return UsdCashCount(
      symbol: symbol.isEmpty ? 'US\$' : symbol,
      rate: rate,
      configuredRate: Decimal.tryParse(raw['configured_rate']?.toString() ?? ''),
      denominations: list,
    );
  }

  @override
  List<Object?> get props => [symbol, rate, configuredRate, denominations];
}

/// Sprint Caja Pro — Una entrada individual del listado de
/// depósitos / retiros / gastos manuales del turno. Aparece en la
/// hoja de cierre (pantalla + papel) para auditar movimiento por
/// movimiento.
class CashMovementEntry extends Equatable {
  final String type;       // 'deposit' | 'withdrawal' | 'expense'
  final double amount;
  final String? reasonLabel;
  final String? description;
  final DateTime createdAt;

  const CashMovementEntry({
    required this.type,
    required this.amount,
    this.reasonLabel,
    this.description,
    required this.createdAt,
  });

  /// Etiqueta legible corta del tipo. Útil para el ticket térmico
  /// donde el ancho es limitado.
  String get typeShortLabel {
    switch (type) {
      case 'deposit':
        return 'Depósito';
      case 'withdrawal':
        return 'Retiro';
      case 'expense':
        return 'Gasto';
      default:
        return type;
    }
  }

  @override
  List<Object?> get props => [type, amount, reasonLabel, description, createdAt];
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

  // Sprint Caja Pro — desglose Toast-style. Cada uno se popla desde
  // fn_get_cash_session_summary y se imprime en el ticket de cierre.
  final int cashSalesNet;
  final int totalDeposits;
  final int totalWithdrawals;
  final int totalExpenses;

  /// Sprint Caja Pro — Listado detallado de movimientos manuales del
  /// turno (deposit/withdrawal/expense). Se renderiza en la hoja de
  /// cierre y en el ticket impreso para auditoría. Vacío = no hubo
  /// movimientos manuales (solo ventas y apertura).
  final List<CashMovementEntry> movements;

  const CashCloseInput({
    required this.expectedCash,
    required this.expectedCard,
    required this.expectedTransfer,
    required this.totalSales,
    required this.transactionCount,
    this.cashierName = 'Admin',
    this.businessName = 'MangoPOS Restaurant',
    this.startAmount = 0,
    this.cashSalesNet = 0,
    this.totalDeposits = 0,
    this.totalWithdrawals = 0,
    this.totalExpenses = 0,
    this.movements = const [],
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
    cashSalesNet,
    totalDeposits,
    totalWithdrawals,
    totalExpenses,
    movements,
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
    // Efectivo contado fuera de las denominaciones RD$: los dólares en
    // gaveta ya convertidos (UsdCashCount.totalDop). 0 = solo pesos.
    int extraCashCounted = 0,
  }) {
    final totalCounted =
        calculateCashCounted(denominations) + extraCashCounted;
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
