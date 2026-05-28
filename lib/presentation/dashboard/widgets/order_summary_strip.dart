// Widget "Order Summary" del dashboard: 5 KPIs en fila con delta vs
// ayer (mismo tramo del día).
//
//   Ingresos | Órdenes totales | En curso | Completadas | Items vendidos
//
// El primer card va destacado en naranja (sin delta — es el headline);
// los otros son blancos con un chip ↑/↓ %.
//
// Datos: provider `dashboardKpisProvider` (un solo fetch trae las 2
// filas HOY + AYER). Moneda: respeta `BusinessCurrency` (no hardcoded
// RD$). Cantidades formateadas con separador de miles (en_US).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../data/models/dashboard_models.dart';
import '../providers/dashboard_providers.dart';

class OrderSummaryStrip extends ConsumerWidget {
  const OrderSummaryStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncKpis = ref.watch(dashboardKpisProvider);
    final currency = currentBusinessCurrencyOrFallback(ref);
    return asyncKpis.when(
      loading: () => const _LoadingSkeleton(),
      error: (_, _) => _ErrorBox(
        onRetry: () => ref.invalidate(dashboardKpisProvider),
      ),
      data: (kpis) => _KpiGrid(kpis: kpis, currency: currency),
    );
  }
}

class _KpiGrid extends StatelessWidget {
  final DashboardKpis kpis;
  final BusinessCurrency currency;
  const _KpiGrid({required this.kpis, required this.currency});

  @override
  Widget build(BuildContext context) {
    final intFmt = NumberFormat('#,##0', 'en_US');
    final qtyFmt = NumberFormat('#,##0.##', 'en_US');

    final cards = <_KpiCardData>[
      _KpiCardData(
        title: 'Ingresos',
        icon: Icons.savings_outlined,
        value: currency.formatter.format(kpis.today.income),
        deltaPercent: kpis.deltaPercent((s) => s.income),
        higherIsBetter: true,
        accent: AppColors.primary,
        primary: true,
      ),
      _KpiCardData(
        title: 'Órdenes totales',
        icon: Icons.receipt_long_outlined,
        value: intFmt.format(kpis.today.ordersTotal),
        deltaPercent:
            kpis.deltaPercent((s) => s.ordersTotal.toDouble()),
        higherIsBetter: true,
        accent: const Color(0xFFF59E0B),
      ),
      _KpiCardData(
        title: 'En curso',
        icon: Icons.local_fire_department_outlined,
        value: intFmt.format(kpis.today.ordersInProgress),
        deltaPercent:
            kpis.deltaPercent((s) => s.ordersInProgress.toDouble()),
        // Más órdenes "en curso" no es necesariamente mejor — es una
        // medida de carga. Mostramos el delta pero sin colorearlo
        // como bueno/malo.
        higherIsBetter: null,
        accent: const Color(0xFF2563EB),
      ),
      _KpiCardData(
        title: 'Completadas',
        icon: Icons.check_circle_outline,
        value: intFmt.format(kpis.today.ordersCompleted),
        deltaPercent:
            kpis.deltaPercent((s) => s.ordersCompleted.toDouble()),
        higherIsBetter: true,
        accent: const Color(0xFF059669),
      ),
      _KpiCardData(
        title: 'Items vendidos',
        icon: Icons.shopping_basket_outlined,
        value: qtyFmt.format(kpis.today.itemsSold),
        deltaPercent: kpis.deltaPercent((s) => s.itemsSold),
        higherIsBetter: true,
        accent: const Color(0xFFDC2626),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Responsive: < 720px → 2 columnas (wrap); 720-1080 → 3 columnas;
        // ≥ 1080 → fila única con los 5.
        final width = constraints.maxWidth;
        final int columns;
        if (width >= 1080) {
          columns = 5;
        } else if (width >= 720) {
          columns = 3;
        } else {
          columns = 2;
        }
        const gap = 12.0;
        final itemWidth =
            (width - gap * (columns - 1)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final data in cards)
              SizedBox(width: itemWidth, child: _KpiCard(data: data)),
          ],
        );
      },
    );
  }
}

class _KpiCardData {
  final String title;
  final IconData icon;
  final String value;
  final double? deltaPercent;
  final bool? higherIsBetter;
  final Color accent;
  final bool primary;
  const _KpiCardData({
    required this.title,
    required this.icon,
    required this.value,
    required this.deltaPercent,
    required this.higherIsBetter,
    required this.accent,
    this.primary = false,
  });
}

class _KpiCard extends StatelessWidget {
  final _KpiCardData data;
  const _KpiCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final isPrimary = data.primary;
    final bgColor = isPrimary ? data.accent : Colors.white;
    final titleColor = isPrimary
        ? Colors.white.withValues(alpha: 0.92)
        : AppColors.mutedForeground;
    final valueColor = isPrimary ? Colors.white : AppColors.foreground;
    final iconBg = isPrimary
        ? Colors.white.withValues(alpha: 0.22)
        : data.accent.withValues(alpha: 0.12);
    final iconFg = isPrimary ? Colors.white : data.accent;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: isPrimary
            ? null
            : Border.all(color: AppColors.border, width: 1),
        boxShadow: isPrimary ? AppShadows.soft : AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(data.icon, size: 18, color: iconFg),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  data.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: titleColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            data.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: valueColor,
              fontFeatures: const [FontFeature.tabularFigures()],
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          _DeltaChip(
            percent: data.deltaPercent,
            higherIsBetter: data.higherIsBetter,
            onDark: isPrimary,
          ),
        ],
      ),
    );
  }
}

class _DeltaChip extends StatelessWidget {
  final double? percent;
  final bool? higherIsBetter;
  final bool onDark;
  const _DeltaChip({
    required this.percent,
    required this.higherIsBetter,
    required this.onDark,
  });

  @override
  Widget build(BuildContext context) {
    final p = percent;
    if (p == null) {
      // Sin baseline ayer (ayer fue 0) → mostrar "—" neutral.
      return Text(
        'Sin comparativa de ayer',
        style: TextStyle(
          fontSize: 11,
          color: onDark
              ? Colors.white.withValues(alpha: 0.75)
              : AppColors.mutedForeground,
        ),
      );
    }

    final isUp = p >= 0;
    final isNeutral = higherIsBetter == null;
    final isGood = isNeutral ? null : (isUp == (higherIsBetter ?? true));

    Color color;
    if (onDark) {
      color = Colors.white;
    } else if (isNeutral) {
      color = AppColors.mutedForeground;
    } else {
      color = isGood == true
          ? const Color(0xFF059669)
          : const Color(0xFFDC2626);
    }

    final abs = p.abs();
    final formatted = abs >= 100
        ? abs.toStringAsFixed(0)
        : abs.toStringAsFixed(1);

    return Row(
      children: [
        Icon(
          isUp ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 2),
        Text(
          '$formatted %',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          'vs ayer',
          style: TextStyle(
            fontSize: 11,
            color: onDark
                ? Colors.white.withValues(alpha: 0.75)
                : AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final int columns =
            width >= 1080 ? 5 : (width >= 720 ? 3 : 2);
        const gap = 12.0;
        final itemWidth = (width - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: List.generate(5, (i) {
            return Container(
              width: itemWidth,
              height: 116,
              decoration: BoxDecoration(
                color: AppColors.secondary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: AppColors.border),
              ),
            );
          }),
        );
      },
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorBox({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline,
              size: 18, color: Color(0xFFDC2626)),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'No se pudieron cargar los KPIs del día.',
              style: TextStyle(
                fontSize: 13,
                color: Color(0xFF991B1B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Reintentar'),
          ),
        ],
      ),
    );
  }
}
