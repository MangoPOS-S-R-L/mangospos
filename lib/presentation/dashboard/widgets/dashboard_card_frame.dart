// Frame y helpers compartidos por los widgets de la Fase A del dashboard
// (Top Selling Items, Recent Orders, Inventory Alert).
//
// Vivían inline en top_selling_items_card.dart pero como los 3 widgets
// usan el mismo card + el mismo skeleton/empty/error pattern, extraídos
// acá para evitar duplicación. Cualquier cambio de estilo (border-radius,
// shadow, padding) toca un solo archivo.

import 'package:flutter/material.dart';

import '../../../app/theme/mango_colors.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';

/// Marco estándar de los widgets del dashboard. Cada uno provee título +
/// (opcional) trailing/subtitle + body.
class DashboardCardFrame extends StatelessWidget {
  final String title;
  /// Pill gris a la derecha del título (ej. "Hoy", "Esta semana").
  /// Si se pasa `trailing`, este se ignora.
  final String? subtitle;
  /// Widget custom a la derecha del título (ej. dropdown, badge dinámico).
  /// Tiene precedencia sobre `subtitle`.
  final Widget? trailing;
  final Widget child;

  const DashboardCardFrame({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppColors.foreground,
                  ),
                ),
              ),
              if (trailing != null)
                trailing!
              else if (subtitle != null)
                _SubtitlePill(text: subtitle!),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _SubtitlePill extends StatelessWidget {
  final String text;
  const _SubtitlePill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.secondary,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppColors.mutedForeground,
        ),
      ),
    );
  }
}

/// Empty state estándar del dashboard. Cuando no hay datos legítimos
/// (sin ventas hoy, sin órdenes recientes, etc.), preferimos un mensaje
/// honesto a un widget vacío que confunde.
class DashboardEmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const DashboardEmptyState({
    super.key,
    required this.icon,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          Icon(icon, size: 36, color: AppColors.mutedForeground),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

/// Error state estándar — banner rojo con botón Reintentar. Mejor que
/// silenciar el error o mostrar "0" que confunde al cajero.
class DashboardErrorBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const DashboardErrorBox({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline,
              color: Color(0xFFDC2626), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF991B1B),
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: MangoColors.primaryOrange,
            ),
            child: const Text('Reintentar'),
          ),
        ],
      ),
    );
  }
}
