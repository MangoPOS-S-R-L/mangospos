import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/report_scaffold.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

class InventoryReportView extends StatelessWidget {
  const InventoryReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ReportScaffold(
      title: 'Inventario',
      category: ReportCategory.inventory,
      body: (state, viewModel) =>
          _InventoryReportBody(state: state, viewModel: viewModel),
    );
  }
}

class _InventoryReportBody extends StatelessWidget {
  const _InventoryReportBody({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final metrics = viewModel.getInventoryMetricCards();
    final topRows = viewModel.getInventoryTopStockRows();
    final alertRows = viewModel.getInventoryAlertRows();
    final movementRows = viewModel.getInventoryMovementRows();

    return ListView(
      padding: reportSectionPadding,
      children: [
        const Text(
          'Visión general de existencias, alertas y movimientos recientes.',
          style: TextStyle(color: AppColors.mutedForeground, fontSize: 15),
        ),
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(
            state.error!,
            style: const TextStyle(color: AppColors.destructive),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        ReportChartCard(
          title: 'Movimientos de inventario',
          rows: movementRows,
          color: const Color(0xFF059669),
        ),
        const SizedBox(height: AppSpacing.itemGap),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn = constraints.maxWidth < AppBreakpoints.tablet;
            final cards = [
              ReportBreakdownCard(
                title: 'Top insumos por existencia',
                emptyText: 'No hay datos de stock para mostrar.',
                emptyIcon: Icons.inventory_outlined,
                children: topRows
                    .map(
                      (row) => ReportAmountRow(
                        label: row.label,
                        trailing: '${row.quantity.toStringAsFixed(2)} uds',
                      ),
                    )
                    .toList(),
              ),
              ReportBreakdownCard(
                title: 'Alertas de inventario',
                emptyText: 'No hay insumos en alerta ahora mismo.',
                emptyIcon: Icons.warning_amber_outlined,
                children: alertRows
                    .map(
                      (row) => ReportAmountRow(
                        label: row.label,
                        trailing: row.amount <= 0
                            ? 'Agotado'
                            : 'Stock ${row.amount.toStringAsFixed(2)} · mín ${row.quantity.toStringAsFixed(2)}',
                      ),
                    )
                    .toList(),
              ),
              ReportBreakdownCard(
                title: 'Movimientos recientes por tipo',
                emptyText: 'No hay movimientos recientes.',
                emptyIcon: Icons.swap_horiz_outlined,
                children: movementRows
                    .map(
                      (row) => ReportAmountRow(
                        label: row.label,
                        trailing:
                            '${row.amount.toStringAsFixed(2)} uds · ${row.count} movs',
                      ),
                    )
                    .toList(),
              ),
            ];

            if (singleColumn) {
              return Column(
                children: [
                  for (int i = 0; i < cards.length; i++) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.itemGap),
                    cards[i],
                  ],
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.itemGap),
                  Expanded(child: cards[i]),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.itemGap),
        Container(
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          decoration: BoxDecoration(
            color: const Color(0xFF059669).withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(reportRadius),
            border: Border.all(
              color: const Color(0xFF059669).withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.assessment_outlined,
                  color: Color(0xFF059669)),
              const SizedBox(width: AppSpacing.tightGap),
              Expanded(
                child: Text(
                  'Valor de inventario estimado: ${currency.format((state.inventorySummary?['total_stock_value'] as num?)?.toDouble() ?? 0)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
