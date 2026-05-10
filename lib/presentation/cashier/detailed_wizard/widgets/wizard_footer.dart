import 'package:flutter/material.dart';

import 'package:mangopos/app/theme/mango_colors.dart';

/// Footer sticky de 56 px con dos botones: secundario izq, primario der.
///
/// `secondaryIcon` se renderiza a la izquierda del label (← para Atrás).
/// `primaryIcon` se renderiza a la derecha del label (→ para Continuar,
/// ✓ para Firmar). Ambos opcionales — sirven como guías visuales de la
/// dirección/acción.
class WizardFooter extends StatelessWidget {
  const WizardFooter({
    super.key,
    required this.secondaryLabel,
    required this.primaryLabel,
    required this.onSecondary,
    required this.onPrimary,
    this.secondaryIcon,
    this.primaryIcon,
    this.primaryEnabled = true,
    this.primaryLoading = false,
  });

  final String secondaryLabel;
  final String primaryLabel;
  final VoidCallback? onSecondary;
  final VoidCallback? onPrimary;
  final IconData? secondaryIcon;
  final IconData? primaryIcon;
  final bool primaryEnabled;
  final bool primaryLoading;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: MangoColors.white,
        border: Border(top: BorderSide(color: MangoColors.cardBorder)),
      ),
      child: Row(
        children: [
          OutlinedButton(
            onPressed: onSecondary,
            style: OutlinedButton.styleFrom(
              foregroundColor: MangoColors.darkGray,
              side: const BorderSide(color: MangoColors.cardBorder),
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (secondaryIcon != null) ...[
                  Icon(secondaryIcon, size: 16),
                  const SizedBox(width: 6),
                ],
                Text(
                  secondaryLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          const Spacer(),
          ElevatedButton(
            onPressed: (primaryEnabled && !primaryLoading) ? onPrimary : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoColors.successGreen,
              foregroundColor: MangoColors.white,
              disabledBackgroundColor: MangoColors.cardBorder,
              disabledForegroundColor: MangoColors.muted,
              padding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 10,
              ),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: primaryLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(MangoColors.white),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        primaryLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (primaryIcon != null) ...[
                        const SizedBox(width: 6),
                        Icon(primaryIcon, size: 16),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
