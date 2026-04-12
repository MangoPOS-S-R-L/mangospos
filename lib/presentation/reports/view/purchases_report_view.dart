import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/report_scaffold.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

class PurchasesReportView extends StatelessWidget {
  const PurchasesReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ReportScaffold(
      title: 'Compras',
      category: ReportCategory.purchases,
      body: (state, viewModel) =>
          _PurchasesReportBody(state: state, viewModel: viewModel),
    );
  }
}

class _PurchasesReportBody extends StatelessWidget {
  const _PurchasesReportBody({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final metrics = viewModel.getPurchaseMetricCards();
    final statusRows = viewModel.getPurchaseStatusRows();
    final supplierRows = viewModel.getPurchaseSupplierRows();

    return ListView(
      padding: reportSectionPadding,
      children: [
        const Text(
          'Resumen de órdenes, recepción y proveedores del período.',
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
          title: 'Compras por estado',
          rows: statusRows,
          color: const Color(0xFF7C3AED),
        ),
        const SizedBox(height: AppSpacing.itemGap),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn = constraints.maxWidth < AppBreakpoints.tablet;
            final cards = [
              ReportBreakdownCard(
                title: 'Órdenes por estado',
                emptyText: 'No hay órdenes en el período.',
                emptyIcon: Icons.receipt_long_outlined,
                children: statusRows
                    .map(
                      (row) => ReportAmountRow(
                        label: row.label,
                        trailing:
                            '${currency.format(row.amount)} · ${row.count} órdenes',
                      ),
                    )
                    .toList(),
              ),
              ReportBreakdownCard(
                title: 'Top proveedores',
                emptyText:
                    'No hay proveedores con órdenes en el período.',
                emptyIcon: Icons.local_shipping_outlined,
                children: supplierRows
                    .map(
                      (row) => ReportAmountRow(
                        label: row.label,
                        trailing:
                            '${currency.format(row.amount)} · ${row.count} órdenes',
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
      ],
    );
  }
}
