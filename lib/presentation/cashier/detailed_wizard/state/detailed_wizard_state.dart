import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';

/// Estado del wizard detallado.
///
/// Reusa los modelos del modo compacto (`DenominationCount`, `CashCloseInput`,
/// `CashCloseCalculator`) para mantener una única fuente de verdad para los
/// cálculos y evitar drift entre modos.
class DetailedWizardState extends Equatable {
  final CashCloseInput input;
  final List<DenominationCount> denominations;
  final String cardInput;
  final String transferInput;
  final String supervisorNote;
  final int currentStep;

  const DetailedWizardState({
    required this.input,
    required this.denominations,
    this.cardInput = '',
    this.transferInput = '',
    this.supervisorNote = '',
    this.currentStep = 0,
  });

  int get totalCounted => CashCloseCalculator.calculateCashCounted(denominations);
  double get numericCard => CashCloseCalculator.parseAmount(cardInput);
  double get numericTransfer =>
      CashCloseCalculator.parseAmount(transferInput);
  double get totalElectronic => numericCard + numericTransfer;
  double get totalReported => totalCounted + totalElectronic;
  int get shiftCash => totalCounted - input.startAmount;

  CashCloseResult get result => CashCloseCalculator.calculate(
    denominations: denominations,
    cardInput: cardInput,
    transferInput: transferInput,
    input: input,
  );

  DetailedWizardState copyWith({
    List<DenominationCount>? denominations,
    String? cardInput,
    String? transferInput,
    String? supervisorNote,
    int? currentStep,
  }) {
    return DetailedWizardState(
      input: input,
      denominations: denominations ?? this.denominations,
      cardInput: cardInput ?? this.cardInput,
      transferInput: transferInput ?? this.transferInput,
      supervisorNote: supervisorNote ?? this.supervisorNote,
      currentStep: currentStep ?? this.currentStep,
    );
  }

  @override
  List<Object?> get props => [
    input,
    denominations,
    cardInput,
    transferInput,
    supervisorNote,
    currentStep,
  ];
}

/// Denominaciones DOP soportadas, en orden descendente. Cada una es un
/// input independiente de cantidad × valor.
///
/// El UI las divide en dos columnas:
///   - "BILLETE":   2000, 1000, 500, 200, 100
///   - "PEQUEÑAS":  50, 25, 10, 5, 1
///
/// `billetesValues` / `pequenasValues` exponen los splits para el step UI.
const _baseDenominations = <DenominationCount>[
  DenominationCount(value: 2000, label: 'RD\$ 2,000'),
  DenominationCount(value: 1000, label: 'RD\$ 1,000'),
  DenominationCount(value: 500, label: 'RD\$ 500'),
  DenominationCount(value: 200, label: 'RD\$ 200'),
  DenominationCount(value: 100, label: 'RD\$ 100'),
  DenominationCount(value: 50, label: 'RD\$ 50'),
  DenominationCount(value: 25, label: 'RD\$ 25'),
  DenominationCount(value: 10, label: 'RD\$ 10'),
  DenominationCount(value: 5, label: 'RD\$ 5'),
  DenominationCount(value: 1, label: 'RD\$ 1'),
];

const billeteValues = [2000, 1000, 500, 200, 100];
const pequenasValues = [50, 25, 10, 5, 1];

class DetailedWizardViewModel extends StateNotifier<DetailedWizardState> {
  DetailedWizardViewModel(CashCloseInput input)
    : super(
        DetailedWizardState(
          input: input,
          denominations: List.unmodifiable(_baseDenominations),
        ),
      );

  void setDenominationCount(int value, int count) {
    final clamped = count < 0 ? 0 : count;
    state = state.copyWith(
      denominations: state.denominations
          .map(
            (d) => d.value == value ? d.copyWith(count: clamped) : d,
          )
          .toList(growable: false),
    );
  }

  void setCardInput(String raw) {
    state = state.copyWith(cardInput: _sanitizeDecimal(raw));
  }

  void setTransferInput(String raw) {
    state = state.copyWith(transferInput: _sanitizeDecimal(raw));
  }

  void setSupervisorNote(String raw) {
    final clipped = raw.length > 500 ? raw.substring(0, 500) : raw;
    state = state.copyWith(supervisorNote: clipped);
  }

  void goToStep(int step) {
    final clamped = step.clamp(0, 2);
    state = state.copyWith(currentStep: clamped);
  }

  /// Snapshot inmutable del estado actual al momento de firmar. Útil para
  /// pasarlo al repo sin race conditions con cambios subsiguientes (que
  /// además están deshabilitados por la pantalla loading).
  DetailedWizardSnapshot snapshot() {
    final denomMap = <String, dynamic>{};
    for (final d in state.denominations) {
      if (d.count == 0) continue;
      denomMap[d.value.toString()] = d.count;
    }
    return DetailedWizardSnapshot(
      cashAmount: state.totalCounted,
      cardAmount: state.numericCard,
      transferAmount: state.numericTransfer,
      denominations: denomMap,
      openingFloat: state.input.startAmount.toDouble(),
      supervisorNote: state.supervisorNote.trim().isEmpty
          ? null
          : state.supervisorNote.trim(),
      result: state.result,
    );
  }

  String _sanitizeDecimal(String raw) {
    if (raw.isEmpty) return '';
    final normalized = raw.replaceAll(',', '.');
    final match = RegExp(r'^\d*\.?\d{0,2}').firstMatch(normalized);
    return match?.group(0) ?? '';
  }
}

/// Datos serializables al cerrar.
class DetailedWizardSnapshot {
  final int cashAmount;
  final double cardAmount;
  final double transferAmount;
  final Map<String, dynamic> denominations;
  final double openingFloat;
  final String? supervisorNote;
  final CashCloseResult result;

  const DetailedWizardSnapshot({
    required this.cashAmount,
    required this.cardAmount,
    required this.transferAmount,
    required this.denominations,
    required this.openingFloat,
    required this.supervisorNote,
    required this.result,
  });
}

final detailedWizardProvider = StateNotifierProvider.autoDispose
    .family<DetailedWizardViewModel, DetailedWizardState, CashCloseInput>(
      (ref, input) => DetailedWizardViewModel(input),
    );
