// Widget "Inventory Alert" del dashboard. Lista hasta N insumos con
// stock bajo/crítico/agotado para que el owner detecte rotura antes que
// los clientes.
//
// Datos vienen del provider `dashboardInventoryAlertsProvider(limit)`,
// que reusa `InventoryRepository.getLowStockAlerts` (lee la vista
// `v_inventory_low_stock`). Levels: out_of_stock | critical | low.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_colors.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/dashboard_models.dart';
import '../providers/dashboard_providers.dart';
import 'dashboard_card_frame.dart';

class InventoryAlertCard extends ConsumerWidget {
  /// Cantidad máxima de alertas a mostrar. Default 4 — más satura el card.
  final int limit;

  const InventoryAlertCard({super.key, this.limit = 4});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncAlerts = ref.watch(dashboardInventoryAlertsProvider(limit));
    return DashboardCardFrame(
      title: 'Alertas de inventario',
      trailing: asyncAlerts.maybeWhen(
        data: (items) => _CountBadge(count: items.length),
        orElse: () => const SizedBox.shrink(),
      ),
      child: asyncAlerts.when(
        loading: () => const _LoadingSkeleton(),
        error: (e, _) => DashboardErrorBox(
          message: 'No se pudo cargar las alertas de stock.',
          onRetry: () =>
              ref.invalidate(dashboardInventoryAlertsProvider(limit)),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const DashboardEmptyState(
              icon: Icons.check_circle_outline,
              message: 'Todo el inventario está en niveles saludables.',
            );
          }
          return Column(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _AlertTile(alert: items[i]),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => context.go(AppRoutes.inventoryKardex),
                  style: FilledButton.styleFrom(
                    backgroundColor: MangoColors.primaryOrange,
                    foregroundColor: MangoColors.white,
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.inventory_2_outlined, size: 18),
                  label: const Text(
                    'Abrir inventario',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  final DashboardInventoryAlert alert;
  const _AlertTile({required this.alert});

  @override
  Widget build(BuildContext context) {
    final colors = _colorsFor(alert.alertLevel);
    final numberFormat = NumberFormat('#,##0.##', 'en_US');
    final unit = alert.unit ?? 'unidades';
    final detail = _buildDetailLine(alert, numberFormat, unit);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colors.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: colors.fg, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.foreground,
                    ),
                    children: [
                      TextSpan(
                        text: alert.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: colors.fg,
                        ),
                      ),
                      TextSpan(text: ' — $detail'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _buildDetailLine(
    DashboardInventoryAlert a,
    NumberFormat fmt,
    String unit,
  ) {
    if (a.isOutOfStock) {
      return 'agotado. Pedir reposición urgente.';
    }
    final stock = fmt.format(a.stock);
    if (a.isCritical) {
      return 'solo $stock $unit. Reponer antes del próximo servicio.';
    }
    final shortfall = a.shortfall;
    if (shortfall != null && shortfall > 0) {
      return '$stock $unit (faltan ${fmt.format(shortfall)} $unit para el mínimo).';
    }
    return '$stock $unit en stock — nivel bajo.';
  }

  static _AlertColors _colorsFor(String level) {
    switch (level) {
      case 'out_of_stock':
        return const _AlertColors(
          bg: Color(0xFFFEE2E2),
          border: Color(0xFFFCA5A5),
          fg: Color(0xFFB91C1C),
        );
      case 'critical':
        return const _AlertColors(
          bg: Color(0xFFFEE2E2),
          border: Color(0xFFFCA5A5),
          fg: Color(0xFFDC2626),
        );
      case 'low':
      default:
        return const _AlertColors(
          bg: Color(0xFFFEF3C7),
          border: Color(0xFFFCD34D),
          fg: Color(0xFFB45309),
        );
    }
  }
}

class _AlertColors {
  final Color bg;
  final Color border;
  final Color fg;
  const _AlertColors({
    required this.bg,
    required this.border,
    required this.fg,
  });
}

class _CountBadge extends StatelessWidget {
  final int count;
  const _CountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.secondary,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 14,
            color: count > 0
                ? const Color(0xFFDC2626)
                : AppColors.mutedForeground,
          ),
          const SizedBox(width: 4),
          Text(
            count == 1 ? '1 alerta' : '$count alertas',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.secondary,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ],
      ],
    );
  }
}
