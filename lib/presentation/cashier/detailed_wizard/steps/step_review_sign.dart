import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';

import '../state/detailed_wizard_state.dart';

/// Paso 3 — Revisar y firmar.
///
/// Resumen read-only de los 3 totales (efectivo, tarjeta, transferencia),
/// total reportado, textarea opcional para nota al supervisor (max 500 chars)
/// y aviso de inmutabilidad post-firma.
class StepReviewSign extends ConsumerStatefulWidget {
  const StepReviewSign({super.key, required this.input});

  final CashCloseInput input;

  @override
  ConsumerState<StepReviewSign> createState() => _StepReviewSignState();
}

class _StepReviewSignState extends ConsumerState<StepReviewSign> {
  late final TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    final initial = ref.read(detailedWizardProvider(widget.input)).supervisorNote;
    _noteController = TextEditingController(text: initial);
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(detailedWizardProvider(widget.input));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _StepIntro(
            title: 'Revisar y firmar',
            description:
                'Confirma los totales reportados antes de firmar el cierre. '
                'Después de firmar, el conteo es inmutable.',
          ),
          const SizedBox(height: 16),
          _SummaryRow(
            label: 'Efectivo',
            value: 'RD\$ ${_formatInt(state.totalCounted)}',
          ),
          const SizedBox(height: 8),
          _SummaryRow(
            label: 'Tarjeta',
            value: formatRDigital(state.numericCard),
          ),
          const SizedBox(height: 8),
          _SummaryRow(
            label: 'Transferencia',
            value: formatRDigital(state.numericTransfer),
          ),
          const SizedBox(height: 16),
          _ReportedTotalCard(value: state.totalReported),
          const SizedBox(height: 16),
          _SupervisorNote(
            controller: _noteController,
            onChanged: (raw) => ref
                .read(detailedWizardProvider(widget.input).notifier)
                .setSupervisorNote(raw),
            charCount: state.supervisorNote.length,
          ),
          const SizedBox(height: 16),
          const _ImmutabilityNotice(),
        ],
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

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: MangoColors.darkGray,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: MangoColors.darkGray,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportedTotalCard extends StatelessWidget {
  const _ReportedTotalCard({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAEEDA),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Total reportado',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: MangoColors.darkGray,
              ),
            ),
          ),
          Text(
            formatRDigital(value),
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 24,
              color: MangoColors.darkGray,
            ),
          ),
        ],
      ),
    );
  }
}

class _SupervisorNote extends StatelessWidget {
  const _SupervisorNote({
    required this.controller,
    required this.onChanged,
    required this.charCount,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final int charCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
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
              const Expanded(
                child: Text(
                  'Nota al supervisor (opcional)',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: MangoColors.darkGray,
                  ),
                ),
              ),
              Text(
                '$charCount/500',
                style: const TextStyle(
                  color: MangoColors.muted,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            onChanged: onChanged,
            maxLines: 4,
            maxLength: 500,
            inputFormatters: [LengthLimitingTextInputFormatter(500)],
            decoration: InputDecoration(
              hintText: 'Algo que el supervisor deba saber sobre este cierre...',
              counterText: '',
              isDense: true,
              contentPadding: const EdgeInsets.all(12),
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

class _ImmutabilityNotice extends StatelessWidget {
  const _ImmutabilityNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFCD34D)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: Color(0xFF92400E), size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Una vez firmado, el conteo no se puede modificar. La diferencia '
              'contra el sistema la verá únicamente el supervisor.',
              style: TextStyle(
                color: Color(0xFF92400E),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatInt(int v) {
  final s = v.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
