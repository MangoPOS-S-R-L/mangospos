import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';

enum BlindCashCloseStep { count, result }

enum BlindCashInputTarget { card, transfer }

class BlindCashCloseState {
  final CashCloseInput input;
  final BlindCashCloseStep step;
  final List<DenominationCount> denominations;
  final String cardInput;
  final String transferInput;
  final BlindCashInputTarget? activeInput;

  const BlindCashCloseState({
    required this.input,
    this.step = BlindCashCloseStep.count,
    this.denominations = const [],
    this.cardInput = '',
    this.transferInput = '',
    this.activeInput,
  });

  int get totalCounted => CashCloseCalculator.calculateCashCounted(denominations);
  double get numericCard => CashCloseCalculator.parseAmount(cardInput);
  double get numericTransfer => CashCloseCalculator.parseAmount(transferInput);
  double get totalReported => totalCounted + numericCard + numericTransfer;
  int get expectedTotal => input.expectedTotal;
  double get difference => totalReported - expectedTotal;

  CashCloseResult get result => CashCloseCalculator.calculate(
        denominations: denominations,
        cardInput: cardInput,
        transferInput: transferInput,
        input: input,
      );

  BlindCashCloseState copyWith({
    BlindCashCloseStep? step,
    List<DenominationCount>? denominations,
    String? cardInput,
    String? transferInput,
    BlindCashInputTarget? activeInput,
    bool clearActiveInput = false,
  }) {
    return BlindCashCloseState(
      input: input,
      step: step ?? this.step,
      denominations: denominations ?? this.denominations,
      cardInput: cardInput ?? this.cardInput,
      transferInput: transferInput ?? this.transferInput,
      activeInput: clearActiveInput ? null : (activeInput ?? this.activeInput),
    );
  }
}

class BlindCashCloseViewModel extends StateNotifier<BlindCashCloseState> {
  static const List<int> _defaultDenominations = [
    2000,
    1000,
    500,
    200,
    100,
    50,
    25,
    10,
    5,
    1,
  ];

  BlindCashCloseViewModel(CashCloseInput input)
      : super(
          BlindCashCloseState(
            input: input,
            denominations: _defaultDenominations
                .map(
                  (v) => DenominationCount(
                    value: v,
                    label: 'RD\$ ${v.toString()}',
                    count: 0,
                  ),
                )
                .toList(growable: false),
          ),
        );

  void increment(int value) {
    _updateDenomination(value, (current) => current + 1);
  }

  void decrement(int value) {
    _updateDenomination(value, (current) => current > 0 ? current - 1 : 0);
  }

  void setCount(int value, int count) {
    _updateDenomination(value, (_) => count < 0 ? 0 : count);
  }

  void _updateDenomination(int value, int Function(int) mapper) {
    final updated = state.denominations
        .map((d) => d.value == value ? d.copyWith(count: mapper(d.count)) : d)
        .toList(growable: false);
    state = state.copyWith(denominations: updated);
  }

  void setActiveInput(BlindCashInputTarget target) {
    state = state.copyWith(activeInput: target);
  }

  void appendNumpad(String value) {
    if (state.activeInput == null) return;

    final current = state.activeInput == BlindCashInputTarget.card
        ? state.cardInput
        : state.transferInput;

    String next;
    switch (value) {
      case 'backspace':
        next = current.isEmpty ? '' : current.substring(0, current.length - 1);
      case 'clear':
        next = '';
      case '.':
        // Only allow one decimal point, and max 2 decimal digits
        if (current.contains('.')) {
          next = current;
        } else {
          next = current.isEmpty ? '0.' : '$current.';
        }
      case '00':
        // Don't allow more than 2 decimal digits
        if (current.contains('.')) {
          final decimals = current.split('.').last;
          if (decimals.length >= 2) {
            next = current;
          } else {
            next = '${current}0';
          }
        } else {
          next = current.isEmpty ? '0' : '$current$value';
        }
      default:
        // Don't allow more than 2 decimal digits
        if (current.contains('.')) {
          final decimals = current.split('.').last;
          if (decimals.length >= 2) {
            next = current;
          } else {
            next = '$current$value';
          }
        } else {
          next = '$current$value';
        }
    }

    if (state.activeInput == BlindCashInputTarget.card) {
      state = state.copyWith(cardInput: next);
    } else {
      state = state.copyWith(transferInput: next);
    }
  }

  void goToResult() {
    state = state.copyWith(step: BlindCashCloseStep.result, clearActiveInput: true);
  }

  void backToCount() {
    state = state.copyWith(step: BlindCashCloseStep.count);
  }

  void reset() {
    final input = state.input;
    state = BlindCashCloseState(
      input: input,
      denominations: state.denominations
          .map((d) => d.copyWith(count: 0))
          .toList(growable: false),
    );
  }
}

final blindCashCloseProvider = StateNotifierProvider.autoDispose
    .family<BlindCashCloseViewModel, BlindCashCloseState, CashCloseInput>(
  (ref, input) => BlindCashCloseViewModel(input),
);

