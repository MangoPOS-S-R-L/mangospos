import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show NumberFormat;

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';

import '../state/detailed_wizard_state.dart';

/// Paso 1 — Efectivo (10 denominaciones DOP).
///
/// Layout:
///   - Banner "a ciegas" arriba.
///   - Dos columnas: BILLETE (2000/1000/500/200/100) + PEQUEÑAS (50/25/10/5/1)
///     lado a lado en ≥ 720 px, apiladas debajo de eso.
///   - Cada columna tiene su propio "subtotal" al final.
///   - "Dólares en gaveta" (solo si la moneda USD está activa en Ajustes →
///     Monedas): billetes US$ + tasa del día, convertidos a RD$ y sumados al
///     total contado.
///   - Cards finales: Fondo inicial (read-only) y Efectivo del turno
///     (= total contado − fondo).
class StepCashCount extends ConsumerWidget {
  const StepCashCount({super.key, required this.input});

  final CashCloseInput input;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(detailedWizardProvider(input));
    final billeteSubtotal = _sumFor(state, billeteValues);
    final pequenasSubtotal = _sumFor(state, pequenasValues);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _StepIntro(
            title: 'Efectivo',
            description:
                'Cuenta los billetes y monedas que tienes en gaveta. '
                'Resta el fondo inicial al final.',
          ),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _DenomColumn(
                    input: input,
                    heading: 'BILLETE',
                    values: billeteValues,
                    subtotalLabel: 'SUBTOTAL BILLETES',
                    subtotal: billeteSubtotal,
                    firstAutofocus: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DenomColumn(
                    input: input,
                    heading: 'PEQUEÑAS',
                    values: pequenasValues,
                    subtotalLabel: 'SUBTOTAL PEQUEÑAS',
                    subtotal: pequenasSubtotal,
                    firstAutofocus: false,
                  ),
                ),
              ],
            ),
          ),
          if (state.usdEnabled) ...[
            const SizedBox(height: 10),
            _UsdSection(input: input),
            const SizedBox(height: 10),
            _CashTotalsCard(
              pesos: state.pesosCounted,
              usdInDop: state.usdInDop,
              total: state.totalCounted,
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _OpeningFloatCard(opening: input.startAmount)),
              const SizedBox(width: 10),
              Expanded(child: _ShiftCashCard(shift: state.shiftCash)),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

int _sumFor(DetailedWizardState state, List<int> values) {
  var sum = 0;
  for (final d in state.denominations) {
    if (values.contains(d.value)) sum += d.subtotal;
  }
  return sum;
}

class _StepIntro extends StatelessWidget {
  const _StepIntro({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: MangoColors.successGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.payments_outlined,
                color: MangoColors.successGreen,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 20,
                color: MangoColors.darkGray,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: const TextStyle(
            color: MangoColors.muted,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _DenomColumn extends StatelessWidget {
  const _DenomColumn({
    required this.input,
    required this.heading,
    required this.values,
    required this.subtotalLabel,
    required this.subtotal,
    required this.firstAutofocus,
  });

  final CashCloseInput input;
  final String heading;
  final List<int> values;
  final String subtotalLabel;
  final int subtotal;
  final bool firstAutofocus;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ColumnHeader(heading: heading),
          for (var i = 0; i < values.length; i++)
            _DenominationRow(
              key: ValueKey('${heading}_${values[i]}'),
              input: input,
              value: values[i],
              autofocus: firstAutofocus && i == 0,
            ),
          _ColumnSubtotal(label: subtotalLabel, value: subtotal),
        ],
      ),
    );
  }
}

class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader({required this.heading});

  final String heading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: MangoColors.cardBorder),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              heading,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 11,
                letterSpacing: 0.6,
                color: MangoColors.muted,
              ),
            ),
          ),
          const Expanded(
            flex: 2,
            child: Text(
              'CANT.',
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 11,
                letterSpacing: 0.6,
                color: MangoColors.muted,
              ),
            ),
          ),
          const SizedBox(
            width: 78,
            child: Text(
              'SUBTOTAL',
              textAlign: TextAlign.end,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 11,
                letterSpacing: 0.6,
                color: MangoColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DenominationRow extends ConsumerStatefulWidget {
  const _DenominationRow({
    super.key,
    required this.input,
    required this.value,
    required this.autofocus,
  });

  final CashCloseInput input;
  final int value;
  final bool autofocus;

  @override
  ConsumerState<_DenominationRow> createState() => _DenominationRowState();
}

class _DenominationRowState extends ConsumerState<_DenominationRow> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final initial = ref
        .read(detailedWizardProvider(widget.input))
        .denominations
        .firstWhere((d) => d.value == widget.value)
        .count;
    _controller = TextEditingController(
      text: initial == 0 ? '' : initial.toString(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    final parsed = int.tryParse(raw) ?? 0;
    ref
        .read(detailedWizardProvider(widget.input).notifier)
        .setDenominationCount(widget.value, parsed);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(detailedWizardProvider(widget.input));
    final denom = state.denominations.firstWhere(
      (d) => d.value == widget.value,
    );
    final subtotal = denom.subtotal;
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: MangoColors.cardBorder),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(flex: 3, child: _DenomLabel(label: denom.label)),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _controller,
                autofocus: widget.autofocus,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: _onChanged,
                style: const TextStyle(
                  fontSize: 14,
                  color: MangoColors.darkGray,
                ),
                decoration: _countFieldDecoration(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 78,
            child: Text(
              _format(subtotal),
              textAlign: TextAlign.end,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 14,
                color: subtotal > 0
                    ? MangoColors.darkGray
                    : MangoColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DenomLabel extends StatelessWidget {
  const _DenomLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFFAF6E8),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 13,
            color: MangoColors.darkGray,
          ),
        ),
      ),
    );
  }
}

class _ColumnSubtotal extends StatelessWidget {
  const _ColumnSubtotal({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF6E8),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 11,
                letterSpacing: 0.6,
                color: MangoColors.muted,
              ),
            ),
          ),
          Text(
            _format(value),
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 16,
              color: MangoColors.darkGray,
            ),
          ),
        ],
      ),
    );
  }
}

class _OpeningFloatCard extends StatelessWidget {
  const _OpeningFloatCard({required this.opening});

  final int opening;

  @override
  Widget build(BuildContext context) {
    return _SummaryCard(
      title: 'Fondo inicial',
      value: 'RD\$ ${_format(opening)}',
      bg: const Color(0xFFFAF6E8),
    );
  }
}

class _ShiftCashCard extends StatelessWidget {
  const _ShiftCashCard({required this.shift});

  final int shift;

  @override
  Widget build(BuildContext context) {
    final negative = shift < 0;
    final text =
        'RD\$ ${_format(shift.abs())}${negative ? ' (−)' : ''}';
    return _SummaryCard(
      title: 'Efectivo del turno',
      value: text,
      bg: const Color(0xFFFAEEDA),
      valueColor: negative ? const Color(0xFFA32D2D) : MangoColors.darkGray,
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.title,
    required this.value,
    required this.bg,
    this.valueColor,
  });

  final String title;
  final String value;
  final Color bg;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 13,
                color: MangoColors.darkGray,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 16,
              color: valueColor ?? MangoColors.darkGray,
            ),
          ),
        ],
      ),
    );
  }
}

InputDecoration _countFieldDecoration({
  String hintText = '0',
  String? prefixText,
  String? suffixText,
  bool filled = false,
}) {
  OutlineInputBorder border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: color, width: width),
      );
  return InputDecoration(
    hintText: hintText,
    prefixText: prefixText,
    suffixText: suffixText,
    prefixStyle: const TextStyle(fontSize: 13, color: MangoColors.muted),
    suffixStyle: const TextStyle(fontSize: 12, color: MangoColors.muted),
    isDense: true,
    // Blanco sobre el fondo verde de "Dólares en gaveta"; las filas RD$ van
    // sin relleno, como siempre.
    filled: filled,
    fillColor: filled ? MangoColors.white : null,
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    border: border(MangoColors.cardBorder),
    enabledBorder: border(MangoColors.cardBorder),
    focusedBorder: border(MangoColors.successGreen, width: 2),
  );
}

// ─── Dólares en gaveta ──────────────────────────────────────────────────────

const _usdBg = Color(0xFFF0F8F3);
const _usdBorder = Color(0xFFD5EADB);
const _usdChip = Color(0xFFE1F2E6);
const _usdFooter = Color(0xFFE6F4EA);
const _usdInk = Color(0xFF15803D);

final _usdAmount = NumberFormat('#,##0.00', 'en_US');

/// Tasa RD$ por US$: hasta 4 decimales, igual que en Ajustes → Monedas.
class _RateInputFormatter extends TextInputFormatter {
  const _RateInputFormatter();

  static final RegExp _pattern = RegExp(r'^\d*\.?\d{0,4}$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final normalized = newValue.text.replaceAll(',', '.');
    if (normalized.isEmpty) return newValue.copyWith(text: '');
    if (!_pattern.hasMatch(normalized)) return oldValue;
    return TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
  }
}

class _UsdSection extends ConsumerWidget {
  const _UsdSection({required this.input});

  final CashCloseInput input;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(detailedWizardProvider(input));
    final usd = state.usdCount;
    if (usd == null) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: _usdBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _usdBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _UsdHeader(
            input: input,
            symbol: usd.symbol,
            missingRate: state.usdMissingRate,
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final perRow = w >= 600 ? 3 : (w >= 400 ? 2 : 1);
              final rows = <List<int>>[
                for (var i = 0; i < usdValues.length; i += perRow)
                  usdValues.sublist(
                    i,
                    (i + perRow).clamp(0, usdValues.length),
                  ),
              ];
              return Column(
                children: [
                  for (final row in rows)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: _usdBorder),
                        ),
                      ),
                      child: Row(
                        children: [
                          for (var i = 0; i < perRow; i++) ...[
                            if (i > 0) const SizedBox(width: 16),
                            Expanded(
                              child: i < row.length
                                  ? _UsdDenominationCell(
                                      key: ValueKey('USD_${row[i]}'),
                                      input: input,
                                      value: row[i],
                                      symbol: usd.symbol,
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          _UsdSubtotal(
            symbol: usd.symbol,
            totalUsd: usd.totalUsd,
            totalDop: usd.totalDop,
          ),
        ],
      ),
    );
  }
}

class _UsdHeader extends StatelessWidget {
  const _UsdHeader({
    required this.input,
    required this.symbol,
    required this.missingRate,
  });

  final CashCloseInput input;
  final String symbol;
  final bool missingRate;

  @override
  Widget build(BuildContext context) {
    final title = Row(
      children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _usdChip,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.attach_money, color: _usdInk, size: 18),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Dólares en gaveta',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: MangoColors.darkGray,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Se convierten a RD\$ con la tasa del día para el total '
                'del cierre.',
                style: TextStyle(fontSize: 12, color: MangoColors.muted),
              ),
            ],
          ),
        ),
      ],
    );
    const rateLabel = Text(
      'TASA DEL DÍA',
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 11,
        letterSpacing: 0.6,
        color: MangoColors.muted,
      ),
    );
    final rateField = _UsdRateField(input: input, symbol: symbol);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _usdBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 560) {
                return Row(
                  children: [
                    Expanded(child: title),
                    const SizedBox(width: 12),
                    rateLabel,
                    const SizedBox(width: 10),
                    SizedBox(width: 200, child: rateField),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  title,
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      rateLabel,
                      const SizedBox(width: 10),
                      Expanded(child: rateField),
                    ],
                  ),
                ],
              );
            },
          ),
          if (missingRate) ...[
            const SizedBox(height: 8),
            const Text(
              'Escribe la tasa del día para convertir los dólares a RD\$.',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Color(0xFFA32D2D),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _UsdRateField extends ConsumerStatefulWidget {
  const _UsdRateField({required this.input, required this.symbol});

  final CashCloseInput input;
  final String symbol;

  @override
  ConsumerState<_UsdRateField> createState() => _UsdRateFieldState();
}

class _UsdRateFieldState extends ConsumerState<_UsdRateField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(detailedWizardProvider(widget.input)).usdRateInput,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: TextField(
        controller: _controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.next,
        inputFormatters: const [_RateInputFormatter()],
        onChanged: (raw) => ref
            .read(detailedWizardProvider(widget.input).notifier)
            .setUsdRateInput(raw),
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: _usdInk,
        ),
        decoration: _countFieldDecoration(
          hintText: '0.00',
          prefixText: 'RD\$ ',
          suffixText: '/ ${widget.symbol}1',
          filled: true,
        ),
      ),
    );
  }
}

class _UsdDenominationCell extends ConsumerStatefulWidget {
  const _UsdDenominationCell({
    super.key,
    required this.input,
    required this.value,
    required this.symbol,
  });

  final CashCloseInput input;
  final int value;
  final String symbol;

  @override
  ConsumerState<_UsdDenominationCell> createState() =>
      _UsdDenominationCellState();
}

class _UsdDenominationCellState extends ConsumerState<_UsdDenominationCell> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final initial = ref
        .read(detailedWizardProvider(widget.input))
        .usdDenominations
        .firstWhere((d) => d.value == widget.value)
        .count;
    _controller = TextEditingController(
      text: initial == 0 ? '' : initial.toString(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subtotal = ref
        .watch(detailedWizardProvider(widget.input))
        .usdDenominations
        .firstWhere((d) => d.value == widget.value)
        .subtotal;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: _usdChip,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '${widget.symbol} ${widget.value}',
            maxLines: 1,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: _usdInk,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SizedBox(
            height: 36,
            child: TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (raw) => ref
                  .read(detailedWizardProvider(widget.input).notifier)
                  .setUsdDenominationCount(widget.value, int.tryParse(raw) ?? 0),
              style: const TextStyle(
                fontSize: 14,
                color: MangoColors.darkGray,
              ),
              decoration: _countFieldDecoration(filled: true),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 72,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              _usdAmount.format(subtotal),
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 14,
                color: subtotal > 0 ? MangoColors.darkGray : MangoColors.muted,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _UsdSubtotal extends StatelessWidget {
  const _UsdSubtotal({
    required this.symbol,
    required this.totalUsd,
    required this.totalDop,
  });

  final String symbol;
  final int totalUsd;
  final int totalDop;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: _usdFooter,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'SUBTOTAL DÓLARES',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 11,
                letterSpacing: 0.6,
                color: MangoColors.muted,
              ),
            ),
          ),
          // En pantallas angostas el "≈ RD$" baja de línea en vez de
          // desbordar.
          Flexible(
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  '$symbol ${_usdAmount.format(totalUsd)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: _usdInk,
                  ),
                ),
                Text(
                  '≈ ${formatRDigital(totalDop)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Efectivo RD$ + dólares convertidos = lo que se firma como efectivo contado.
class _CashTotalsCard extends StatelessWidget {
  const _CashTotalsCard({
    required this.pesos,
    required this.usdInDop,
    required this.total,
  });

  final int pesos;
  final int usdInDop;
  final int total;

  @override
  Widget build(BuildContext context) {
    final parts = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TotalsPart(label: 'EFECTIVO RD\$', value: _usdAmount.format(pesos)),
        const SizedBox(width: 24),
        _TotalsPart(
          label: 'DÓLARES EN RD\$',
          value: _usdAmount.format(usdInDop),
        ),
      ],
    );
    final grandTotal = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Text(
          'TOTAL EFECTIVO CONTADO',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 11,
            letterSpacing: 0.6,
            color: MangoColors.muted,
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            formatRDigital(total),
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 24,
              color: _usdInk,
            ),
          ),
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 520) {
            return Row(
              children: [
                parts,
                const SizedBox(width: 16),
                Expanded(child: grandTotal),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [parts, const SizedBox(height: 10), grandTotal],
          );
        },
      ),
    );
  }
}

class _TotalsPart extends StatelessWidget {
  const _TotalsPart({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 11,
            letterSpacing: 0.6,
            color: MangoColors.muted,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 16,
            color: MangoColors.darkGray,
          ),
        ),
      ],
    );
  }
}

String _format(int v) {
  final s = v.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
