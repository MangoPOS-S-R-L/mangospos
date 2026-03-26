import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';

class SplitPreviewCard extends StatelessWidget {
  final OrderCheck check;
  final VoidCallback onPay;

  const SplitPreviewCard({super.key, required this.check, required this.onPay});

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.simpleCurrency(
      name: 'RD\$ ',
      decimalDigits: 2,
    );
    final isPaid =
        check.isClosed || check.total <= 0.01; // Assuming closed means paid

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SalesTheme.border),
      ),
      child: Row(
        children: [
          // Color coded ring (Badge)
          Container(
            width: 4,
            height: 32,
            decoration: BoxDecoration(
              color: isPaid ? const Color(0xFF22C55E) : const Color(0xFFF97316),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  check.label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: SalesTheme.foreground,
                  ),
                ),
                Text(
                  currency.format(check.total),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: isPaid ? const Color(0xFF22C55E) : SalesTheme.foreground,
                  ),
                ),
              ],
            ),
          ),
          // Actions
          if (isPaid)
            const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 20)
          else
            ElevatedButton(
              onPressed: onPay,
              style: ElevatedButton.styleFrom(
                backgroundColor: SalesTheme.primary,
                foregroundColor: Colors.white,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Pagar',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
    );
  }
}
