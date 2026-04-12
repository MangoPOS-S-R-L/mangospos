import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/report_scaffold.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

class TaxReportView extends StatelessWidget {
  const TaxReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ReportScaffold(
      title: 'Impuestos',
      category: ReportCategory.taxes,
      body: (state, viewModel) =>
          _TaxReportBody(state: state, viewModel: viewModel),
    );
  }
}

class _TaxReportBody extends StatelessWidget {
  const _TaxReportBody({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final metrics = viewModel.getTaxMetricCards();
    final taxRows = viewModel.getTaxTypeRows();
    final totalCharges =
        taxRows.fold<double>(0, (sum, row) => sum + row.amount);

    return ListView(
      padding: reportSectionPadding,
      children: [
        ReportHeroCard(
          title: 'Impuestos',
          subtitle:
              'Vista fiscal limpia para revisar ITBIS, propina de ley y base gravable sin ruido visual.',
          accentColor: MangoColors.primaryOrange,
          trailing: [
            ReportHeroStat(
              label: 'Tipos con movimiento',
              value: '${taxRows.length}',
            ),
            ReportHeroStat(
              label: 'Total fiscal',
              value: currency.format(totalCharges),
            ),
          ],
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
          title: 'Impuestos y ley por tipo',
          rows: taxRows,
          color: MangoColors.primaryOrange,
        ),
        const SizedBox(height: AppSpacing.itemGap),
        ReportSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ReportSectionLabel(
                title: 'Detalle por tipo',
                subtitle:
                    'Cada fila muestra monto cobrado, base imponible y volumen de items.',
              ),
              const SizedBox(height: AppSpacing.lg),
              if (taxRows.isEmpty)
                const ReportEmptyPlaceholder(
                  icon: Icons.receipt_outlined,
                  message:
                      'No hay impuestos o propina de ley generados en el rango.',
                )
              else
                ...taxRows.map(
                  (row) => ReportLedgerRow(
                    label: row.label,
                    primaryValue: currency.format(row.amount),
                    secondaryValue:
                        'Base ${currency.format(row.quantity)} · ${row.count} items',
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
