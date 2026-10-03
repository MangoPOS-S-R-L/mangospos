import 'package:decimal/decimal.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:mangopos/core/currency/usd_display_settings.dart';
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

  /// Config USD de Ajustes → Monedas. `null` o apagada = sin sección de
  /// dólares y el cierre queda exactamente como antes (solo RD$).
  final UsdDisplaySettings? usdSettings;
  final List<DenominationCount> usdDenominations;

  /// Tasa del día tal como la escribe el cajero (arranca con la de Ajustes).
  final String usdRateInput;

  const DetailedWizardState({
    required this.input,
    required this.denominations,
    this.cardInput = '',
    this.transferInput = '',
    this.supervisorNote = '',
    this.currentStep = 0,
    this.usdSettings,
    this.usdDenominations = _baseUsdDenominations,
    this.usdRateInput = '',
  });

  bool get usdEnabled => usdSettings?.enabled ?? false;

  /// Dólares contados con la tasa del día. `null` si el módulo está apagado.
  UsdCashCount? get usdCount {
    final settings = usdSettings;
    if (settings == null || !settings.enabled) return null;
    return UsdCashCount(
      symbol: settings.symbol,
      rate: Decimal.tryParse(usdRateInput) ?? Decimal.zero,
      configuredRate: settings.rate,
      denominations: usdDenominations,
    );
  }

  /// Contó dólares pero no hay tasa con qué convertirlos: no se deja avanzar.
  bool get usdMissingRate {
    final usd = usdCount;
    return usd != null && !usd.isEmpty && usd.rate <= Decimal.zero;
  }

  int get usdInDop => usdCount?.totalDop ?? 0;

  /// Solo billetes y monedas RD$.
  int get pesosCounted =>
      CashCloseCalculator.calculateCashCounted(denominations);

  /// Todo el efectivo de la gaveta en RD$ (pesos + dólares convertidos).
  int get totalCounted => pesosCounted + usdInDop;
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
    extraCashCounted: usdInDop,
  );

  DetailedWizardState copyWith({
    List<DenominationCount>? denominations,
    String? cardInput,
    String? transferInput,
    String? supervisorNote,
    int? currentStep,
    UsdDisplaySettings? usdSettings,
    List<DenominationCount>? usdDenominations,
    String? usdRateInput,
  }) {
    return DetailedWizardState(
      input: input,
      denominations: denominations ?? this.denominations,
      cardInput: cardInput ?? this.cardInput,
      transferInput: transferInput ?? this.transferInput,
      supervisorNote: supervisorNote ?? this.supervisorNote,
      currentStep: currentStep ?? this.currentStep,
      usdSettings: usdSettings ?? this.usdSettings,
      usdDenominations: usdDenominations ?? this.usdDenominations,
      usdRateInput: usdRateInput ?? this.usdRateInput,
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
    usdSettings,
    usdDenominations,
    usdRateInput,
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

/// Billetes de dólar que se cuentan en "Dólares en gaveta". El label se arma
/// en la UI con el símbolo de Ajustes, por eso va vacío.
const _baseUsdDenominations = <DenominationCount>[
  DenominationCount(value: 100, label: ''),
  DenominationCount(value: 50, label: ''),
  DenominationCount(value: 20, label: ''),
  DenominationCount(value: 10, label: ''),
  DenominationCount(value: 5, label: ''),
  DenominationCount(value: 1, label: ''),
];

const usdValues = [100, 50, 20, 10, 5, 1];

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

  /// Activa "Dólares en gaveta" si el negocio tiene la moneda USD encendida.
  /// La tasa arranca con la de Ajustes; si el cajero ya escribió una, se
  /// respeta.
  void configureUsd(UsdDisplaySettings settings) {
    if (!settings.enabled) return;
    state = state.copyWith(
      usdSettings: settings,
      usdRateInput: state.usdRateInput.isEmpty
          ? _rateText(settings.rate)
          : state.usdRateInput,
    );
  }

  void setUsdDenominationCount(int value, int count) {
    final clamped = count < 0 ? 0 : count;
    state = state.copyWith(
      usdDenominations: state.usdDenominations
          .map(
            (d) => d.value == value ? d.copyWith(count: clamped) : d,
          )
          .toList(growable: false),
    );
  }

  void setUsdRateInput(String raw) {
    state = state.copyWith(usdRateInput: _sanitizeDecimal(raw, decimals: 4));
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

  /// Resetea el conteo a cero: efectivo (todas las denominaciones),
  /// tarjeta, transferencia, nota de supervisor. Mantiene `input` y
  /// resetea `currentStep` a 0. Para el flujo "Volver a contar" cuando
  /// el cajero detecta un error antes de firmar.
  void resetCounts() {
    state = DetailedWizardState(
      input: state.input,
      denominations: List.unmodifiable(_baseDenominations),
      usdSettings: state.usdSettings,
      usdRateInput: _rateText(state.usdSettings?.rate),
    );
  }

  /// Snapshot inmutable del estado actual al momento de firmar. Útil para
  /// pasarlo al repo sin race conditions con cambios subsiguientes (que
  /// además están deshabilitados por la pantalla loading). El caller
  /// pasa `attemptNumber` (1 original, 2 reconteo) para que la fila
  /// nueva de `cash_count_blind` use el attempt correcto.
  DetailedWizardSnapshot snapshot({int attemptNumber = 1}) {
    final denomMap = <String, dynamic>{};
    for (final d in state.denominations) {
      if (d.count == 0) continue;
      denomMap[d.value.toString()] = d.count;
    }
    // Los dólares van en su propia llave: la reimpresión lee las llaves
    // numéricas como billetes RD$ y esta la ignora (ver _denominationsFromJson).
    final usd = state.usdCount;
    final usdCounted = usd != null && !usd.isEmpty ? usd : null;
    if (usdCounted != null) denomMap['usd'] = usdCounted.toJson();
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
      attemptNumber: attemptNumber,
      usd: usdCounted,
    );
  }

  String _sanitizeDecimal(String raw, {int decimals = 2}) {
    if (raw.isEmpty) return '';
    final normalized = raw.replaceAll(',', '.');
    final match =
        RegExp('^\\d*\\.?\\d{0,$decimals}').firstMatch(normalized);
    return match?.group(0) ?? '';
  }

  static String _rateText(Decimal? rate) =>
      rate == null || rate <= Decimal.zero ? '' : rate.toString();
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
  /// Número del intento (1 = original, 2 = reconteo). El wizard lo
  /// incrementa cuando el cajero pulsa "Volver a contar" en el step
  /// de resultado. El caller debe pasar este valor al repositorio para
  /// que la fila nueva de `cash_count_blind` use el attempt correcto.
  final int attemptNumber;

  /// Dólares contados (ya incluidos en [cashAmount] convertidos a RD$).
  /// `null` = no hubo dólares o el módulo USD está apagado.
  final UsdCashCount? usd;

  const DetailedWizardSnapshot({
    required this.cashAmount,
    required this.cardAmount,
    required this.transferAmount,
    required this.denominations,
    required this.openingFloat,
    required this.supervisorNote,
    required this.result,
    this.attemptNumber = 1,
    this.usd,
  });
}

final detailedWizardProvider = StateNotifierProvider.autoDispose
    .family<DetailedWizardViewModel, DetailedWizardState, CashCloseInput>(
      (ref, input) => DetailedWizardViewModel(input),
    );
