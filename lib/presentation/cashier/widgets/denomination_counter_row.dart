import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';

class DenominationCounterRow extends StatefulWidget {
  final DenominationCount denomination;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final ValueChanged<int> onCountChanged;

  const DenominationCounterRow({
    super.key,
    required this.denomination,
    required this.onIncrement,
    required this.onDecrement,
    required this.onCountChanged,
  });

  @override
  State<DenominationCounterRow> createState() => _DenominationCounterRowState();
}

class _DenominationCounterRowState extends State<DenominationCounterRow> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.denomination.count.toString());
  }

  @override
  void didUpdateWidget(covariant DenominationCounterRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.denomination.count != widget.denomination.count) {
      _controller.text = widget.denomination.count.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 124,
            child: Text(
              formatRD(widget.denomination.value),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
            ),
          ),
          IconButton(
            onPressed: widget.onDecrement,
            style: IconButton.styleFrom(
              backgroundColor: MangoColors.bgLight,
              foregroundColor: MangoColors.darkGray,
            ),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: MangoColors.bgLight,
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 6,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: MangoColors.cardBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: MangoColors.primaryOrange),
                ),
              ),
              onChanged: (value) {
                final parsed = int.tryParse(value) ?? 0;
                widget.onCountChanged(parsed < 0 ? 0 : parsed);
              },
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: widget.onIncrement,
            style: IconButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange.withValues(alpha: 0.12),
              foregroundColor: MangoColors.primaryOrange,
            ),
            icon: const Icon(Icons.add_circle_outline),
          ),
          const Spacer(),
          Text(
            formatRD(widget.denomination.subtotal),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                ),
          ),
        ],
      ),
    );
  }
}
