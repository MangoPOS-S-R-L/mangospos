import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';

import '../state/detailed_wizard_state.dart';

/// Paso 1 — Efectivo (10 denominaciones DOP).
///
/// Layout:
///   - Banner "a ciegas" arriba.
///   - Dos columnas: BILLETE (2000/1000/500/200/100) + PEQUEÑAS (50/25/10/5/1)
///     lado a lado en ≥ 720 px, apiladas debajo de eso.
///   - Cada columna tiene su propio "subtotal" al final.
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
                decoration: InputDecoration(
                  hintText: '0',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(
                      color: MangoColors.cardBorder,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(
                      color: MangoColors.cardBorder,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(
                      color: MangoColors.successGreen,
                      width: 2,
                    ),
                  ),
                ),
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

String _format(int v) {
  final s = v.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
