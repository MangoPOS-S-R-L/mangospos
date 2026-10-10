import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/models/ventas_table.dart';

/// Texto de la marca de cuentas en revisión (20261010_0020). Con cuenta
/// principal con consumo: «2 cuentas · revisar» (decisión del dueño); si solo
/// queda la de revisión (la principal ya se cobró): «Cuenta por revisar».
String reviewAccountsLabel(VentasTable table) {
  if (table.reviewAccounts <= 0) return '';
  final hasCurrent = (table.total ?? 0) > 0;
  final count = table.reviewAccounts + (hasCurrent ? 1 : 0);
  return count >= 2 ? '$count cuentas · revisar' : 'Cuenta por revisar';
}

/// Marca roja de la mesa con cuentas en revisión. La comparten la cuadrícula
/// ([TableCard]) y el plano ([ZoneFloorMap]).
class ReviewAccountsBadge extends StatelessWidget {
  final VentasTable table;
  final double fontSize;

  const ReviewAccountsBadge({
    super.key,
    required this.table,
    this.fontSize = 10.5,
  });

  @override
  Widget build(BuildContext context) {
    final label = reviewAccountsLabel(table);
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.destructive.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.call_split_rounded,
            size: fontSize + 0.5,
            color: AppColors.destructive,
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
                color: AppColors.destructive,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
