import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';
import 'package:mangopos/presentation/split_bill/widgets/split_preview_card.dart';

class SplitPreviewPanel extends ConsumerWidget {
  final Order order;
  final List<OrderCheck> checks;
  final Function(OrderCheck) onPayCheck;

  const SplitPreviewPanel({
    super.key,
    required this.order,
    required this.checks,
    required this.onPayCheck,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (checks.isEmpty) return const SizedBox.shrink();

    final allPaid = checks.every((c) => c.isClosed || c.total <= 0.01);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SalesTheme.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Cuentas Divididas',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: SalesTheme.foreground,
                ),
              ),
              if (allPaid)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF22C55E).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Todas completadas',
                    style: TextStyle(
                      color: const Color(0xFF22C55E),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ...checks.map(
            (check) => Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: SplitPreviewCard(
                check: check,
                onPay: () => onPayCheck(check),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
