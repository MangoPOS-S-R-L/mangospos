import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';

import '../state/detailed_wizard_state.dart';

/// Permite montos con centavos: dígitos, un separador decimal y hasta dos
/// decimales. Normaliza la coma a punto (teclados es_DO usan coma) para que
/// coincida con `_sanitizeDecimal` del notifier. Rechaza cualquier entrada
/// que no calce con el patrón, conservando el valor previo.
class _DecimalMoneyInputFormatter extends TextInputFormatter {
  const _DecimalMoneyInputFormatter();

  static final RegExp _pattern = RegExp(r'^\d*\.?\d{0,2}$');

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

/// Paso 2 — Tarjeta y Transferencia.
///
/// Dos cards (lado a lado ≥ 600 px, stack < 600 px) cada una con un input
/// decimal. Al pie, card cream con "Total pagos electrónicos" calculado.
class StepCardTransfer extends ConsumerWidget {
  const StepCardTransfer({super.key, required this.input});

  final CashCloseInput input;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(detailedWizardProvider(input));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 600;
          final cards = [
            _MethodInput(
              icon: Icons.credit_card_outlined,
              title: 'Tarjeta',
              description:
                  'Suma de todos los pagos cobrados con tarjeta durante el turno.',
              initial: state.cardInput,
              autofocus: true,
              onChanged: (raw) => ref
                  .read(detailedWizardProvider(input).notifier)
                  .setCardInput(raw),
            ),
            _MethodInput(
              icon: Icons.swap_horiz_rounded,
              title: 'Transferencia',
              description:
                  'Suma de transferencias bancarias recibidas durante el turno.',
              initial: state.transferInput,
              onChanged: (raw) => ref
                  .read(detailedWizardProvider(input).notifier)
                  .setTransferInput(raw),
            ),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _StepIntro(
                title: 'Pagos electrónicos',
                description: 'Reporta el total cobrado por cada método.',
              ),
              const SizedBox(height: 16),
              if (wide)
                Row(
                  children: [
                    Expanded(child: cards[0]),
                    const SizedBox(width: 16),
                    Expanded(child: cards[1]),
                  ],
                )
              else
                Column(
                  children: [
                    cards[0],
                    const SizedBox(height: 16),
                    cards[1],
                  ],
                ),
              const SizedBox(height: 16),
              _TotalCard(total: state.totalElectronic),
            ],
          );
        },
      ),
    );
  }
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
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: MangoColors.darkGray,
          ),
        ),
        const SizedBox(height: 6),
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

class _MethodInput extends StatefulWidget {
  const _MethodInput({
    required this.icon,
    required this.title,
    required this.description,
    required this.initial,
    required this.onChanged,
    this.autofocus = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final String initial;
  final ValueChanged<String> onChanged;
  final bool autofocus;

  @override
  State<_MethodInput> createState() => _MethodInputState();
}

class _MethodInputState extends State<_MethodInput> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(widget.icon, color: MangoColors.successGreen, size: 22),
              const SizedBox(width: 8),
              Text(
                widget.title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: MangoColors.darkGray,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            widget.description,
            style: const TextStyle(color: MangoColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: widget.autofocus,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            inputFormatters: const [_DecimalMoneyInputFormatter()],
            onChanged: widget.onChanged,
            decoration: InputDecoration(
              prefixText: 'RD\$ ',
              hintText: '0.00',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: MangoColors.cardBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: MangoColors.cardBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                  color: MangoColors.successGreen,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.total});

  final double total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF6E8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Total pagos electrónicos',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: MangoColors.darkGray,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Tarjeta + Transferencia',
                  style: TextStyle(color: MangoColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          Text(
            formatRDigital(total),
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 22,
              color: MangoColors.darkGray,
            ),
          ),
        ],
      ),
    );
  }
}
