import 'package:flutter/material.dart';

import 'package:mangopos/app/theme/mango_colors.dart';

import 'zoom_control.dart';

/// Header del wizard detallado. 56 px de alto, fixed.
///
/// Render: ícono + título + subtítulo + badge "A ciegas" + control de zoom
/// + close button.
///
/// El zoom escala el textScaler del wizard entre 0.85× y 1.50×, default 1.0×.
/// El factor lo maneja el wizard (estado local) y se inyecta vía
/// `zoomFactor` / `onZoomChanged`.
class WizardHeader extends StatelessWidget {
  const WizardHeader({
    super.key,
    this.cashierName,
    this.cashRegisterLabel,
    this.openedAt,
    this.onClose,
    this.zoomFactor = 1.0,
    this.onZoomChanged,
  });

  final String? cashierName;
  final String? cashRegisterLabel;
  final DateTime? openedAt;
  final VoidCallback? onClose;
  final double zoomFactor;
  final ValueChanged<double>? onZoomChanged;

  @override
  Widget build(BuildContext context) {
    final subtitle = _buildSubtitle();
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: MangoColors.white,
        border: Border(bottom: BorderSide(color: MangoColors.cardBorder)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.lock_outline,
            color: MangoColors.successGreen,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Cierre de caja',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: MangoColors.darkGray,
                    height: 1.1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: MangoColors.muted,
                      height: 1.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const _ModeBadge(),
          if (onZoomChanged != null) ...[
            const SizedBox(width: 8),
            ZoomControl(factor: zoomFactor, onChanged: onZoomChanged!),
          ],
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Cerrar',
            icon: const Icon(Icons.close, color: MangoColors.darkGray),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }

  String? _buildSubtitle() {
    final parts = <String>[];
    if (cashRegisterLabel != null && cashRegisterLabel!.isNotEmpty) {
      parts.add(cashRegisterLabel!);
    }
    if (cashierName != null && cashierName!.isNotEmpty) {
      parts.add(cashierName!);
    }
    if (openedAt != null) {
      parts.add(_formatDate(openedAt!));
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  String _formatDate(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd/$mm/${d.year}';
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFEDE9FE),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.visibility_off_outlined,
            size: 12,
            color: Color(0xFF6D28D9),
          ),
          SizedBox(width: 4),
          Text(
            'A ciegas',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Color(0xFF6D28D9),
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
