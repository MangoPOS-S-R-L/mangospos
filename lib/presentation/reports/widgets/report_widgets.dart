import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_shadows.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';

const double reportRadius = 10.0;
const EdgeInsets reportSectionPadding = EdgeInsets.fromLTRB(
  AppSpacing.containerPadding,
  0,
  AppSpacing.containerPadding,
  AppSpacing.containerPadding,
);

ButtonStyle reportOutlineButtonStyle() {
  return OutlinedButton.styleFrom(
    foregroundColor: MangoColors.primaryOrange,
    backgroundColor: Colors.white,
    side: const BorderSide(color: MangoColors.primaryOrange),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(reportRadius),
    ),
    textStyle: const TextStyle(fontWeight: FontWeight.w700),
  );
}

// ---------------------------------------------------------------------------
// Metrics wrap builder
// ---------------------------------------------------------------------------

Widget buildMetricsWrap(List<SalesMetricCardData> metrics) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final availableWidth = constraints.maxWidth;
      const cardMinWidth = 220.0;
      final cols = (availableWidth / (cardMinWidth + AppSpacing.itemGap))
          .floor()
          .clamp(1, metrics.length);
      final cardWidth =
          (availableWidth - (cols - 1) * AppSpacing.itemGap) / cols;

      return Wrap(
        spacing: AppSpacing.itemGap,
        runSpacing: AppSpacing.itemGap,
        children: metrics
            .map(
              (metric) => SizedBox(
                width: cardWidth,
                child: ReportMetricCard(
                  title: metric.title,
                  value: metric.value,
                  subtitle: metric.subtitle,
                  icon: metric.icon,
                  color: metric.color,
                ),
              ),
            )
            .toList(),
      );
    },
  );
}

// ---------------------------------------------------------------------------
// MetricCard
// ---------------------------------------------------------------------------

class ReportMetricCard extends StatefulWidget {
  const ReportMetricCard({
    super.key,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;

  @override
  State<ReportMetricCard> createState() => _ReportMetricCardState();
}

class _ReportMetricCardState extends State<ReportMetricCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(reportRadius),
          border: Border.all(
            color: _isHovered
                ? widget.color.withValues(alpha: 0.3)
                : AppColors.border,
          ),
          boxShadow: _isHovered ? AppShadows.cardInteractive : AppShadows.soft,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(reportRadius),
              ),
              child: Icon(widget.icon, color: widget.color),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              widget.title,
              style: const TextStyle(
                color: AppColors.mutedForeground,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.value,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: AppColors.foreground,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.subtitle,
              style: const TextStyle(
                color: AppColors.mutedForeground,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CommercialStatTile
// ---------------------------------------------------------------------------

class CommercialStatTile extends StatelessWidget {
  const CommercialStatTile({
    super.key,
    required this.label,
    required this.value,
    required this.hint,
  });

  final String label;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(reportRadius),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.mutedForeground,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            style: const TextStyle(
              color: AppColors.mutedForeground,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ChartCard (bar chart)
// ---------------------------------------------------------------------------

class ReportChartCard extends StatelessWidget {
  const ReportChartCard({
    super.key,
    required this.title,
    required this.rows,
    required this.color,
  });

  final String title;
  final List<SalesBreakdownRow> rows;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final visibleRows = rows.take(8).toList(growable: false);
    final maxY = visibleRows.isEmpty
        ? 1.0
        : visibleRows
                  .map((e) => e.amount > 0 ? e.amount : e.count.toDouble())
                  .reduce((a, b) => a > b ? a : b) *
              1.2;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(reportRadius),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(Icons.bar_chart_rounded, size: 18, color: color),
              ),
              const SizedBox(width: AppSpacing.tightGap),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (visibleRows.isEmpty)
            const ReportEmptyPlaceholder(
              icon: Icons.bar_chart_outlined,
              message: 'No hay datos suficientes para graficar.',
            )
          else
            SizedBox(
              height: 240,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: maxY,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: AppColors.border,
                      strokeWidth: 1,
                      dashArray: [4, 4],
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        getTitlesWidget: (value, meta) => Text(
                          NumberFormat.compact().format(value),
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppColors.mutedForeground,
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= visibleRows.length) {
                            return const SizedBox.shrink();
                          }
                          final label = visibleRows[index].label;
                          final short = label.length > 10
                              ? '${label.substring(0, 10)}…'
                              : label;
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              short,
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: List.generate(visibleRows.length, (index) {
                    final row = visibleRows[index];
                    final y =
                        row.amount > 0 ? row.amount : row.count.toDouble();
                    return BarChartGroupData(
                      x: index,
                      barRods: [
                        BarChartRodData(
                          toY: y,
                          width: 24,
                          borderRadius:
                              BorderRadius.circular(AppRadius.sm),
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [color, color.withValues(alpha: 0.7)],
                          ),
                        ),
                      ],
                    );
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// BreakdownCard
// ---------------------------------------------------------------------------

class ReportBreakdownCard extends StatelessWidget {
  const ReportBreakdownCard({
    super.key,
    required this.title,
    required this.children,
    required this.emptyText,
    this.emptyIcon = Icons.info_outline,
  });

  final String title;
  final List<Widget> children;
  final String emptyText;
  final IconData emptyIcon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(reportRadius),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
          const Divider(height: AppSpacing.sectionGap),
          if (children.isEmpty)
            ReportEmptyPlaceholder(icon: emptyIcon, message: emptyText)
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: children.length,
              separatorBuilder: (_, index) => Divider(
                height: 1,
                color: AppColors.border.withValues(alpha: 0.5),
              ),
              itemBuilder: (_, index) => children[index],
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AmountRow
// ---------------------------------------------------------------------------

class ReportAmountRow extends StatelessWidget {
  const ReportAmountRow({
    super.key,
    required this.label,
    required this.trailing,
  });

  final String label;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.tightGap),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: AppSpacing.tightGap),
          Flexible(
            child: Text(
              trailing,
              style: const TextStyle(
                color: AppColors.mutedForeground,
                fontSize: 13,
              ),
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// EmptyPlaceholder
// ---------------------------------------------------------------------------

class ReportEmptyPlaceholder extends StatelessWidget {
  const ReportEmptyPlaceholder({
    super.key,
    required this.icon,
    required this.message,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sectionGap),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: AppColors.secondary.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: AppColors.mutedForeground),
            ),
            const SizedBox(height: AppSpacing.tightGap),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.mutedForeground,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SurfaceCard
// ---------------------------------------------------------------------------

class ReportSurfaceCard extends StatelessWidget {
  const ReportSurfaceCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(reportRadius),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: AppShadows.soft,
      ),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// HeroCard
// ---------------------------------------------------------------------------

class ReportHeroCard extends StatelessWidget {
  const ReportHeroCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.accentColor,
    required this.trailing,
  });

  final String title;
  final String subtitle;
  final Color accentColor;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return ReportSurfaceCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          final stats = Wrap(
            spacing: AppSpacing.itemGap,
            runSpacing: AppSpacing.itemGap,
            children: trailing,
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _heroCopy(),
                const SizedBox(height: AppSpacing.lg),
                stats,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _heroCopy()),
              const SizedBox(width: AppSpacing.sectionGap),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: stats,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _heroCopy() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(reportRadius),
          ),
          child: Icon(Icons.analytics_outlined, color: accentColor),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          title,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 14,
            height: 1.4,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// HeroStat
// ---------------------------------------------------------------------------

class ReportHeroStat extends StatelessWidget {
  const ReportHeroStat({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: MangoColors.bgLight,
        borderRadius: BorderRadius.circular(reportRadius),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.mutedForeground,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SectionLabel
// ---------------------------------------------------------------------------

class ReportSectionLabel extends StatelessWidget {
  const ReportSectionLabel({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 13,
            height: 1.35,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// LedgerRow
// ---------------------------------------------------------------------------

class ReportLedgerRow extends StatelessWidget {
  const ReportLedgerRow({
    super.key,
    required this.label,
    required this.primaryValue,
    required this.secondaryValue,
  });

  final String label;
  final String primaryValue;
  final String secondaryValue;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: MangoColors.cardBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.itemGap),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                primaryValue,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                secondaryValue,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// StatusTag
// ---------------------------------------------------------------------------

class ReportStatusTag extends StatelessWidget {
  const ReportStatusTag({
    super.key,
    required this.label,
    required this.tone,
  });

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(reportRadius),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: tone,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// RangeChip
// ---------------------------------------------------------------------------

class ReportRangeChip extends StatefulWidget {
  const ReportRangeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<ReportRangeChip> createState() => _ReportRangeChipState();
}

class _ReportRangeChipState extends State<ReportRangeChip> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? MangoColors.primaryOrange
                : _isHovered
                    ? MangoColors.primaryOrange.withValues(alpha: 0.08)
                    : Colors.white,
            borderRadius: BorderRadius.circular(reportRadius),
            border: Border.all(
              color: widget.selected
                  ? MangoColors.primaryOrange
                  : _isHovered
                      ? MangoColors.primaryOrange.withValues(alpha: 0.3)
                      : MangoColors.cardBorder,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color:
                  widget.selected ? Colors.white : AppColors.foreground,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// DocumentTypeChip
// ---------------------------------------------------------------------------

class ReportDocumentTypeChip extends StatelessWidget {
  const ReportDocumentTypeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(reportRadius),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? MangoColors.primaryOrange : Colors.white,
          borderRadius: BorderRadius.circular(reportRadius),
          border: Border.all(
            color: selected
                ? MangoColors.primaryOrange
                : MangoColors.cardBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : AppColors.foreground,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TotalPill
// ---------------------------------------------------------------------------

class ReportTotalPill extends StatelessWidget {
  const ReportTotalPill({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.mutedForeground,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.foreground,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}
