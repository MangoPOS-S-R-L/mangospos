import 'package:flutter/material.dart';

import 'package:mangopos/app/theme/mango_colors.dart';

/// Control compacto de zoom con botones `−` / `+` y un label central
/// mostrando el porcentaje actual. Default 100%.
///
/// Pensado para insertarse en el header de los modales de cierre (compact y
/// detailed) y permitir al cajero ajustar el tamaño cuando el modal queda
/// apretado en monitores chicos. El factor lo aplica el wizard envolviendo
/// su body en un `MediaQuery` con `textScaler` proporcional.
class ZoomControl extends StatelessWidget {
  const ZoomControl({
    super.key,
    required this.factor,
    required this.onChanged,
    this.min = 0.85,
    this.max = 1.50,
    this.step = 0.05,
  });

  final double factor;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final double step;

  @override
  Widget build(BuildContext context) {
    final percent = (factor * 100).round();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: MangoColors.bgLight,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomButton(
            icon: Icons.remove,
            tooltip: 'Reducir tamaño',
            enabled: factor > min + 0.001,
            onTap: () {
              final next = (factor - step).clamp(min, max);
              if ((next - factor).abs() > 0.001) onChanged(next);
            },
          ),
          GestureDetector(
            onTap: () => onChanged(1.0),
            child: SizedBox(
              width: 44,
              child: Text(
                '$percent%',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: MangoColors.darkGray,
                ),
              ),
            ),
          ),
          _ZoomButton(
            icon: Icons.add,
            tooltip: 'Aumentar tamaño',
            enabled: factor < max - 0.001,
            onTap: () {
              final next = (factor + step).clamp(min, max);
              if ((next - factor).abs() > 0.001) onChanged(next);
            },
          ),
        ],
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            icon,
            size: 14,
            color: enabled ? MangoColors.darkGray : MangoColors.muted,
          ),
        ),
      ),
    );
  }
}
