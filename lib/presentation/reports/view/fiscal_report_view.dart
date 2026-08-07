import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/fiscal/ncf_types.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/fiscal_documents_detail_card.dart';
import 'package:mangopos/presentation/reports/widgets/report_scaffold.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

class FiscalReportView extends StatelessWidget {
  const FiscalReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ReportScaffold(
      title: 'Comprobantes fiscales',
      category: ReportCategory.fiscal,
      body: (state, viewModel) =>
          _FiscalReportBody(state: state, viewModel: viewModel),
    );
  }
}

class _FiscalReportBody extends StatelessWidget {
  const _FiscalReportBody({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  // _ncfTypeName eliminado: ahora se usa `ncfTypeName(code)` de
  // core/fiscal/ncf_types.dart (catálogo único para toda la app).

  @override
  Widget build(BuildContext context) {
    final currency = state.currency.formatter;
    final cachedAt = viewModel.fiscalDataCachedAt;
    final metrics = viewModel.getFiscalMetricCards();
    final typeRows = viewModel.getFiscalTypeRows();
    final taxBreakdownRows = viewModel.getFiscalTaxBreakdownRows();
    final documents = viewModel.getFilteredFiscalDocuments();
    final availableTypes = viewModel.getAvailableFiscalTypes();
    final selectedType = state.fiscalTypeFilter;

    return ListView(
      padding: reportBodyPadding(context),
      children: [
        ReportHeroCard(
          title: 'Ventas por recibo / comprobante',
          subtitle:
              'Diseño listo para operar por rango de fecha y tipo de comprobante como filtros de primer nivel.',
          period: formatReportPeriod(state),
          accentColor: MangoColors.primaryOrange,
          trailing: [
            ReportHeroStat(
              label: 'Documentos visibles',
              value: '${documents.length}',
            ),
            ReportHeroStat(
              label: 'Filtro activo',
              value: selectedType == null
                  ? 'Todos'
                  : ncfTypeName(selectedType),
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
        if (cachedAt != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          OfflineDataBanner(cachedAt: cachedAt),
        ],
        const SizedBox(height: AppSpacing.xl),
        buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        ReportSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ReportSectionLabel(
                title: 'Filtros del reporte',
                subtitle:
                    'El rango de fecha se controla desde la barra superior; aquí priorizamos el tipo de comprobante.',
              ),
              const SizedBox(height: AppSpacing.lg),
              Wrap(
                spacing: AppSpacing.tightGap,
                runSpacing: AppSpacing.tightGap,
                children: [
                  ReportDocumentTypeChip(
                    label: 'Todos',
                    selected: selectedType == null,
                    onTap: () => viewModel.setFiscalTypeFilter(null),
                  ),
                  ...availableTypes.map(
                    (type) => ReportDocumentTypeChip(
                      label: ncfTypeName(type),
                      selected: selectedType == type,
                      onTap: () => viewModel.setFiscalTypeFilter(type),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sectionGap),
        ReportChartCard(
          title: 'Comprobantes por tipo',
          rows: typeRows,
          color: MangoColors.primaryOrange,
        ),
        const SizedBox(height: AppSpacing.itemGap),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn = constraints.maxWidth < AppBreakpoints.tablet;
            final cards = [
              ReportBreakdownCard(
                title: 'Resumen por tipo de NCF',
                emptyText:
                    'No hay comprobantes fiscales emitidos en el rango.',
                emptyIcon: Icons.description_outlined,
                children: typeRows
                    .map(
                      (row) => ReportAmountRow(
                        label: row.label,
                        trailing:
                            '${currency.format(row.amount)} · ${row.count} docs',
                      ),
                    )
                    .toList(),
              ),
              ReportBreakdownCard(
                title: 'Desglose por impuesto',
                emptyText:
                    'No hay impuestos generados en los comprobantes.',
                emptyIcon: Icons.account_balance_outlined,
                children: taxBreakdownRows
                    .map(
                      (row) => ReportAmountRow(
                        label: row.label,
                        trailing:
                            '${currency.format(row.amount)} · Base ${currency.format(row.quantity)} · ${row.count} docs',
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
        const SizedBox(height: AppSpacing.sectionGap),
        FiscalDocumentsDetailCard(
          documents: documents,
          currency: currency,
          serviceFeeLabel:
              (state.fiscalSummary?['service_fee_label'] as String?)
                          ?.trim()
                          .isNotEmpty ==
                      true
                  ? (state.fiscalSummary!['service_fee_label'] as String).trim()
                  : 'Cargo de servicio',
          subtitle:
              'Tabla lista para auditoría diaria y exportación; respeta el filtro de tipo seleccionado.',
          emptyMessage:
              'No hay comprobantes fiscales en el rango seleccionado.',
          showVoided: state.showVoidedFiscalDocuments,
          voidedCount: viewModel.getVoidedFiscalDocumentsCount(
            applyTypeFilter: true,
          ),
          onToggleVoided: viewModel.setShowVoidedFiscalDocuments,
        ),
      ],
    );
  }
}
