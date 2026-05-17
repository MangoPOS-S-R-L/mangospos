import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_shadows.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/services/reports_csv_export_service.dart';
import 'package:mangopos/presentation/reports/services/reports_export_service.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/fiscal_documents_detail_card.dart';
import 'package:mangopos/presentation/reports/widgets/report_scaffold.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

class SalesReportView extends StatelessWidget {
  const SalesReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ReportScaffold(
      title: 'Informe de ventas',
      category: ReportCategory.sales,
      body: (state, viewModel) =>
          _SalesReportBody(state: state, viewModel: viewModel),
    );
  }
}

class _SalesReportBody extends StatelessWidget {
  const _SalesReportBody({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2, locale: 'en_US');
    final numberFormat = NumberFormat('#,##0', 'en_US');
    final summary = state.salesSummary ?? const <String, dynamic>{};
    final metrics = viewModel.getSalesMetricCards();
    final selectedSub = state.salesSubReport;
    final displayTo = state.salesTo.subtract(const Duration(days: 1));
    final totalAdjustments =
        (summary['discounts_total'] as num?)?.toDouble() ?? 0;
    final totalModifiers =
        (summary['modifier_sales_total'] as num?)?.toDouble() ?? 0;

    final isMobile = ResponsiveHelper.isMobile(context);
    final cardPad = isMobile ? 14.0 : AppSpacing.cardPadding;
    Widget pdfBtn() => OutlinedButton.icon(
          style: reportOutlineButtonStyle(),
          onPressed: () async {
            await ReportsExportService.exportCurrentReport(
              category: ReportCategory.sales,
              state: state,
              viewModel: viewModel,
            );
          },
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
          label: const Text('PDF'),
        );
    Widget csvBtn() => OutlinedButton.icon(
          style: reportOutlineButtonStyle(),
          onPressed: () async {
            await ReportsCsvExportService.exportCurrentReport(
              category: ReportCategory.sales,
              state: state,
              viewModel: viewModel,
            );
          },
          icon: const Icon(Icons.table_view_outlined, size: 18),
          label: const Text('CSV'),
        );

    return ListView(
      padding: reportBodyPadding(context),
      children: [
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(
            state.error!,
            style: const TextStyle(color: AppColors.destructive),
          ),
        ],
        SizedBox(height: isMobile ? AppSpacing.itemGap : AppSpacing.xl),
        Container(
          padding: EdgeInsets.all(cardPad),
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
                    padding: EdgeInsets.all(isMobile ? 8 : 10),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(reportRadius),
                    ),
                    child: Icon(
                      Icons.insights_outlined,
                      color: AppColors.primary,
                      size: isMobile ? 18 : 24,
                    ),
                  ),
                  SizedBox(width: isMobile ? 10 : AppSpacing.itemGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Informe de ventas',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: isMobile ? 15 : 18,
                            fontWeight: FontWeight.w800,
                            color: AppColors.foreground,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Período ${DateFormat('dd MMM yyyy').format(state.salesFrom)} – ${DateFormat('dd MMM yyyy').format(displayTo)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.mutedForeground,
                            fontSize: isMobile ? 11.5 : 13,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!isMobile) ...[
                    const SizedBox(width: AppSpacing.tightGap),
                    pdfBtn(),
                    const SizedBox(width: AppSpacing.tightGap),
                    csvBtn(),
                  ],
                ],
              ),
              if (isMobile) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: pdfBtn()),
                    const SizedBox(width: 8),
                    Expanded(child: csvBtn()),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  const Icon(Icons.filter_list_outlined,
                      size: 18, color: AppColors.mutedForeground),
                  const SizedBox(width: 8),
                  const Text(
                    'Tipo de reporte:',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: AppColors.foreground,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<SalesSubReport>(
                      initialValue: selectedSub,
                      isExpanded: true,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: AppColors.background,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(reportRadius),
                          borderSide:
                              const BorderSide(color: AppColors.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(reportRadius),
                          borderSide:
                              const BorderSide(color: AppColors.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(reportRadius),
                          borderSide:
                              const BorderSide(color: AppColors.primary),
                        ),
                      ),
                      items: SalesSubReport.values.map((sub) {
                        return DropdownMenuItem<SalesSubReport>(
                          value: sub,
                          child: Text(
                            viewModel.salesSubReportLabel(sub),
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          viewModel.setSalesSubReport(value);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < AppBreakpoints.tablet;
                  final stats = [
                    CommercialStatTile(
                      label: 'Ventas netas',
                      value: currency.format(
                        (summary['net_sales'] as num?)?.toDouble() ?? 0,
                      ),
                      hint:
                          '${(summary['payments_count'] as num?)?.toInt() ?? 0} transacciones',
                    ),
                    CommercialStatTile(
                      label: 'Descuentos',
                      value: currency.format(totalAdjustments),
                      hint:
                          '${(summary['discounted_lines_count'] as num?)?.toInt() ?? 0} líneas impactadas',
                    ),
                    CommercialStatTile(
                      label: 'Ingreso por modificadores',
                      value: currency.format(totalModifiers),
                      hint:
                          '${viewModel.getModifierRows().length} modificadores con venta',
                    ),
                  ];
                  if (narrow) {
                    return Column(
                      children: [
                        for (var i = 0; i < stats.length; i++) ...[
                          if (i > 0)
                            const SizedBox(height: AppSpacing.tightGap),
                          stats[i],
                        ],
                      ],
                    );
                  }
                  return Row(
                    children: [
                      for (var i = 0; i < stats.length; i++) ...[
                        if (i > 0) const SizedBox(width: AppSpacing.tightGap),
                        Expanded(child: stats[i]),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sectionGap),
        buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        ..._buildSubReportContent(context, selectedSub, currency),
      ],
    );
  }

  List<Widget> _buildSubReportContent(
    BuildContext context,
    SalesSubReport sub,
    NumberFormat currency,
  ) {
    switch (sub) {
      case SalesSubReport.overview:
        final methodRows = viewModel.getPaymentMethodRows();
        return [
          ReportChartCard(
            title: 'Distribución de ventas por pago',
            rows: methodRows,
            color: AppColors.primary,
          ),
          const Divider(color: AppColors.border),
          const SizedBox(height: AppSpacing.sectionGap),
          _SalesCommercialReportCard(
            title: 'Ventas por categoría',
            subtitle: 'Qué familias del menú están empujando la facturación.',
            icon: Icons.category_outlined,
            color: const Color(0xFF2563EB),
            rows: viewModel.getCategoryRows(),
            emptyText: 'No hay ventas por categoría en el rango.',
            showQuantity: true,
            amountLabel: 'Ventas',
            countLabel: 'Líneas',
            onViewAll: () => viewModel.setSalesSubReport(SalesSubReport.byCategory),
          ),
          const SizedBox(height: AppSpacing.sectionGap),
          const Divider(color: AppColors.border),
          const SizedBox(height: AppSpacing.sectionGap),
          _SalesCommercialReportCard(
            title: 'Ventas por empleado',
            subtitle: 'Rendimiento comercial por colaborador asignado.',
            icon: Icons.person_outline,
            color: const Color(0xFF7C3AED),
            rows: viewModel.getEmployeeRows(),
            emptyText: 'No hay ventas por empleado en el rango.',
            amountLabel: 'Ventas',
            countLabel: 'Órdenes',
            onViewAll: () => viewModel.setSalesSubReport(SalesSubReport.byEmployee),
          ),
          const SizedBox(height: AppSpacing.sectionGap),
          const Divider(color: AppColors.border),
          const SizedBox(height: AppSpacing.sectionGap),
          _SalesCommercialReportCard(
            title: 'Ventas por tipo de pago',
            subtitle: 'Composición de ingresos por método de cobro.',
            icon: Icons.payments_outlined,
            color: const Color(0xFF059669),
            rows: viewModel.getPaymentMethodRows(),
            emptyText: 'No hay pagos en el rango seleccionado.',
            amountLabel: 'Cobrado',
            countLabel: 'Pagos',
            onViewAll: () => viewModel.setSalesSubReport(SalesSubReport.byPayment),
          ),
        ];
      case SalesSubReport.byCategory:
        return [
          _SalesCommercialReportCard(
            title: 'Ventas por categoría',
            subtitle:
                'Qué familias del menú están empujando la facturación.',
            icon: Icons.category_outlined,
            color: const Color(0xFF2563EB),
            rows: viewModel.getCategoryRows(),
            emptyText: 'No hay ventas por categoría en el rango.',
            showQuantity: true,
            amountLabel: 'Ventas',
            countLabel: 'Tickets',
            isFullReport: true,
          ),
        ];
      case SalesSubReport.byEmployee:
        return [
          _SalesCommercialReportCard(
            title: 'Ventas por empleado',
            subtitle: 'Rendimiento comercial por colaborador asignado.',
            icon: Icons.person_outline,
            color: const Color(0xFF7C3AED),
            rows: viewModel.getEmployeeRows(),
            emptyText: 'No hay ventas por empleado en el rango.',
            amountLabel: 'Ventas',
            countLabel: 'Órdenes',
            isFullReport: true,
          ),
        ];
      case SalesSubReport.byPayment:
        return [
          ReportChartCard(
            title: 'Distribución de ventas por pago',
            rows: viewModel.getPaymentMethodRows(),
            color: AppColors.primary,
          ),
          const Divider(color: AppColors.border),
          const SizedBox(height: AppSpacing.sectionGap),
          _SalesCommercialReportCard(
            title: 'Ventas por tipo de pago',
            subtitle: 'Composición de ingresos por método de cobro.',
            icon: Icons.payments_outlined,
            color: const Color(0xFF059669),
            rows: viewModel.getPaymentMethodRows(),
            emptyText: 'No hay pagos en el rango seleccionado.',
            amountLabel: 'Cobrado',
            countLabel: 'Pagos',
            isFullReport: true,
          ),
        ];
      case SalesSubReport.byReceipt:
        return [
          _SalesCommercialReportCard(
            title: 'Ventas por recibo / comprobante',
            subtitle:
                'Balance entre recibos estándar, divididos y comprobantes fiscales.',
            icon: Icons.receipt_long_outlined,
            color: const Color(0xFFF97316),
            rows: viewModel.getReceiptRows(),
            emptyText: 'No hay recibos o comprobantes en el rango.',
            amountLabel: 'Facturado',
            countLabel: 'Documentos',
            isFullReport: true,
          ),
          const SizedBox(height: AppSpacing.sectionGap),
          // Detalle por comprobante: cada NCF listado con cliente, RNC,
          // impuestos por tipo y tag de estado (Activo / Anulado).
          // Mismo widget que usa el reporte de Comprobantes Fiscales.
          FiscalDocumentsDetailCard(
            documents: viewModel.getFiscalDocuments(),
          ),
        ];
      case SalesSubReport.byModifiers:
        return [
          _SalesCommercialReportCard(
            title: 'Ventas por modificadores',
            subtitle: 'Adicionales que empujan el ticket promedio.',
            icon: Icons.tune_outlined,
            color: const Color(0xFF0891B2),
            rows: viewModel.getModifierRows(),
            emptyText: 'No hay modificadores cobrados en el rango.',
            showQuantity: true,
            amountLabel: 'Ingreso',
            countLabel: 'Aplicaciones',
            isFullReport: true,
          ),
        ];
      case SalesSubReport.byDiscounts:
        return [
          _SalesCommercialReportCard(
            title: 'Descuentos y cortesías',
            subtitle:
                'Controla el impacto comercial de descuentos y concesiones.',
            icon: Icons.local_offer_outlined,
            color: const Color(0xFFDC2626),
            rows: viewModel.getDiscountRows(),
            emptyText: 'No hay descuentos ni cortesías aplicados.',
            showQuantity: true,
            amountLabel: 'Impacto',
            countLabel: 'Líneas',
            isFullReport: true,
          ),
        ];
      case SalesSubReport.byProduct:
        final productSalesRows = viewModel.getFilteredProductSalesRows();
        final productCategories =
            viewModel.getAvailableProductSalesCategories();
        final productTotals = productSalesRows.fold<Map<String, double>>(
          <String, double>{
            'quantity': 0,
            'projection': 0,
            'grossSales': 0,
            'discounts': 0,
            'courtesies': 0,
            'netSales': 0,
            'cost': 0,
            'grossProfit': 0,
          },
          (totals, row) {
            totals['quantity'] =
                (totals['quantity'] ?? 0) + row.quantitySold;
            totals['projection'] =
                (totals['projection'] ?? 0) + row.projectedQuantity;
            totals['grossSales'] =
                (totals['grossSales'] ?? 0) + row.grossSales;
            totals['discounts'] =
                (totals['discounts'] ?? 0) + row.discounts;
            totals['courtesies'] =
                (totals['courtesies'] ?? 0) + row.courtesies;
            totals['netSales'] =
                (totals['netSales'] ?? 0) + row.netSales;
            totals['cost'] = (totals['cost'] ?? 0) + row.cost;
            totals['grossProfit'] =
                (totals['grossProfit'] ?? 0) + row.grossProfit;
            return totals;
          },
        );
        return [
          _ProductSalesReportSection(
            state: state,
            viewModel: viewModel,
            rows: productSalesRows,
            categories: productCategories,
            totals: productTotals,
            currency: currency,
          ),
        ];
      case SalesSubReport.byZone:
        return [
          _SalesCommercialReportCard(
            title: 'Ventas por zona',
            subtitle: 'Distribución de ingresos por zona del local.',
            icon: Icons.place_outlined,
            color: const Color(0xFF0891B2),
            rows: viewModel.getZoneRows(),
            emptyText: 'No hay ventas por zona en el rango.',
            amountLabel: 'Ventas',
            countLabel: 'Órdenes',
            isFullReport: true,
          ),
        ];
      case SalesSubReport.byHour:
        return [
          ReportChartCard(
            title: 'Ventas por hora',
            rows: viewModel.getHourlyRows(),
            color: const Color(0xFF7C3AED),
          ),
          const Divider(color: AppColors.border),
          const SizedBox(height: AppSpacing.sectionGap),
          _SalesCommercialReportCard(
            title: 'Ventas por hora',
            subtitle: 'Actividad de ventas por franja horaria.',
            icon: Icons.schedule_outlined,
            color: const Color(0xFF7C3AED),
            rows: viewModel.getHourlyRows(),
            emptyText: 'No hay actividad en el rango.',
            amountLabel: 'Ventas',
            countLabel: 'Transacciones',
            isFullReport: true,
          ),
        ];
    }
  }
}

// ---------------------------------------------------------------------------
// Sales-specific widgets
// ---------------------------------------------------------------------------

class _SalesCommercialReportCard extends StatelessWidget {
  const _SalesCommercialReportCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.rows,
    required this.emptyText,
    required this.amountLabel,
    required this.countLabel,
    this.showQuantity = false,
    this.onViewAll,
    this.isFullReport = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final List<SalesBreakdownRow> rows;
  final String emptyText;
  final String amountLabel;
  final String countLabel;
  final bool showQuantity;
  final VoidCallback? onViewAll;
  final bool isFullReport;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2, locale: 'en_US');
    final numberFormat = NumberFormat('#,##0', 'en_US');
    final totalAmount = rows.fold<double>(0, (sum, row) => sum + row.amount);
    final totalCount = rows.fold<int>(0, (sum, row) => sum + row.count);
    final totalQuantity =
        rows.fold<double>(0, (sum, row) => sum + row.quantity);
    final leader = rows.isEmpty ? 'Sin datos' : rows.first.label;

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
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(reportRadius),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: AppSpacing.itemGap),
              Expanded(
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
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.mutedForeground,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isFullReport && onViewAll != null && rows.length > 6)
                TextButton.icon(
                  onPressed: onViewAll,
                  icon: const Icon(Icons.arrow_forward, size: 16),
                  label: const Text('Ver todo'),
                  style: TextButton.styleFrom(
                    foregroundColor: color,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: CommercialStatTile(
                  label: amountLabel,
                  value: currency.format(totalAmount),
                  hint: 'Total acumulado',
                ),
              ),
              const SizedBox(width: AppSpacing.tightGap),
              Expanded(
                child: CommercialStatTile(
                  label: countLabel,
                  value: numberFormat.format(totalCount),
                  hint: showQuantity
                      ? '${numberFormat.format(totalQuantity)} unidades'
                      : 'Movimientos registrados',
                ),
              ),
              const SizedBox(width: AppSpacing.tightGap),
              Expanded(
                child: CommercialStatTile(
                  label: 'Líder',
                  value: leader,
                  hint: rows.isEmpty ? 'Sin actividad' : 'Primer lugar',
                ),
              ),
            ],
          ),
          const Divider(height: AppSpacing.sectionGap),
          if (rows.isEmpty)
            ReportEmptyPlaceholder(icon: icon, message: emptyText)
          else
            _SalesCommercialTable(
              rows: isFullReport ? rows : rows.take(6).toList(growable: false),
              showQuantity: showQuantity,
              amountLabel: amountLabel,
              countLabel: countLabel,
            ),
        ],
      ),
    );
  }
}

class _SalesCommercialTable extends StatelessWidget {
  const _SalesCommercialTable({
    required this.rows,
    required this.showQuantity,
    required this.amountLabel,
    required this.countLabel,
  });

  final List<SalesBreakdownRow> rows;
  final bool showQuantity;
  final String amountLabel;
  final String countLabel;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2, locale: 'en_US');
    final numberFormat = NumberFormat('#,##0', 'en_US');
    final totalAmount = rows.fold<double>(0, (sum, row) => sum + row.amount);
    final totalCount = rows.fold<int>(0, (sum, row) => sum + row.count);
    final totalQuantity =
        rows.fold<double>(0, (sum, row) => sum + row.quantity);

    Widget buildHeaderCell(String text, {TextAlign align = TextAlign.start}) {
      return Text(
        text,
        textAlign: align,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.mutedForeground,
        ),
      );
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(reportRadius),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Expanded(flex: 4, child: buildHeaderCell('Concepto')),
              Expanded(
                flex: 2,
                child: buildHeaderCell('Cantidad', align: TextAlign.end),
              ),
              Expanded(
                flex: 2,
                child: buildHeaderCell(countLabel, align: TextAlign.end),
              ),
              Expanded(
                flex: 3,
                child: buildHeaderCell(amountLabel, align: TextAlign.end),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < rows.length; i++) ...[
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: i.isEven ? Colors.white : AppColors.background,
              borderRadius: BorderRadius.circular(reportRadius),
              border: Border.all(
                color: AppColors.border.withValues(alpha: 0.7),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Text(
                    rows[i].label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    showQuantity
                        ? numberFormat.format(rows[i].quantity)
                        : '—',
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      color: AppColors.mutedForeground,
                      fontSize: 13,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    numberFormat.format(rows[i].count),
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      color: AppColors.mutedForeground,
                      fontSize: 13,
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    currency.format(rows[i].amount),
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (i < rows.length - 1) const SizedBox(height: 8),
        ],
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(reportRadius),
            border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              const Expanded(
                flex: 4,
                child: Text(
                  'Total mostrado',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppColors.foreground,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  showQuantity ? totalQuantity.toStringAsFixed(0) : '—',
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  numberFormat.format(totalCount),
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  currency.format(totalAmount),
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
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

class _ProductSalesReportSection extends StatelessWidget {
  const _ProductSalesReportSection({
    required this.state,
    required this.viewModel,
    required this.rows,
    required this.categories,
    required this.totals,
    required this.currency,
  });

  final ReportsState state;
  final ReportsViewModel viewModel;
  final List<ProductSalesReportRow> rows;
  final List<String> categories;
  final Map<String, double> totals;
  final NumberFormat currency;

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
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: MangoColors.primaryOrange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(reportRadius),
                ),
                child: const Icon(
                  Icons.inventory_2_outlined,
                  color: MangoColors.primaryOrange,
                ),
              ),
              const SizedBox(width: AppSpacing.itemGap),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ventas por producto',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Reporte tabular serio para medir unidades, descuentos, costo y ganancia por producto.',
                      style: TextStyle(
                        color: AppColors.mutedForeground,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < AppBreakpoints.tablet;
              final searchField = TextFormField(
                key: ValueKey(
                    'product-sales-query-${state.productSalesQuery}'),
                initialValue: state.productSalesQuery,
                onChanged: viewModel.setProductSalesQuery,
                decoration: InputDecoration(
                  hintText: 'Buscar producto o categoría',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(reportRadius),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(reportRadius),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(reportRadius),
                    borderSide: const BorderSide(
                        color: MangoColors.primaryOrange),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                ),
              );
              final categoryField = DropdownButtonFormField<String>(
                initialValue: state.productSalesCategoryFilter,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Categoría',
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(reportRadius),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(reportRadius),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(reportRadius),
                    borderSide: const BorderSide(
                        color: MangoColors.primaryOrange),
                  ),
                ),
                items: [
                  const DropdownMenuItem<String>(
                    value: null,
                    child: Text('Todas las categorías'),
                  ),
                  ...categories.map(
                    (category) => DropdownMenuItem<String>(
                      value: category,
                      child: Text(category),
                    ),
                  ),
                ],
                onChanged: viewModel.setProductSalesCategoryFilter,
              );
              final clearButton = SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  style: reportOutlineButtonStyle(),
                  onPressed: viewModel.clearProductSalesFilters,
                  icon: const Icon(Icons.filter_alt_off_outlined),
                  label: const Text('Limpiar filtros'),
                ),
              );

              if (stacked) {
                return Column(
                  children: [
                    searchField,
                    const SizedBox(height: AppSpacing.itemGap),
                    categoryField,
                    const SizedBox(height: AppSpacing.itemGap),
                    Align(
                        alignment: Alignment.centerLeft,
                        child: clearButton),
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(flex: 3, child: searchField),
                  const SizedBox(width: AppSpacing.itemGap),
                  Expanded(flex: 2, child: categoryField),
                  const SizedBox(width: AppSpacing.itemGap),
                  clearButton,
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.tightGap,
            runSpacing: AppSpacing.tightGap,
            children: [
              CommercialStatTile(
                label: 'Productos visibles',
                value: '${rows.length}',
                hint: 'Filtrados sobre el rango activo',
              ),
              CommercialStatTile(
                label: 'Unidades vendidas',
                value: (totals['quantity'] ?? 0).toStringAsFixed(2),
                hint: 'Cantidad consolidada',
              ),
              CommercialStatTile(
                label: 'Ventas netas',
                value: currency.format(totals['netSales'] ?? 0),
                hint: 'Después de descuentos y cortesías',
              ),
              CommercialStatTile(
                label: 'Ganancia bruta',
                value: currency.format(totals['grossProfit'] ?? 0),
                hint: 'Netas menos costo registrado',
              ),
            ]
                .map((tile) => SizedBox(width: 220, child: tile))
                .toList(growable: false),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (rows.isEmpty)
            const ReportEmptyPlaceholder(
              icon: Icons.inventory_2_outlined,
              message:
                  'No hay productos que coincidan con los filtros del rango seleccionado.',
            )
          else
            _ProductSalesDataTable(
                rows: rows, totals: totals, currency: currency),
        ],
      ),
    );
  }
}

class _ProductSalesDataTable extends StatelessWidget {
  const _ProductSalesDataTable({
    required this.rows,
    required this.totals,
    required this.currency,
  });

  final List<ProductSalesReportRow> rows;
  final Map<String, double> totals;
  final NumberFormat currency;

  DataColumn _moneyColumn(String label) => DataColumn(
        numeric: true,
        label: Text(label,
            style: const TextStyle(fontWeight: FontWeight.w700)),
      );

  @override
  Widget build(BuildContext context) {
    final visibleRows = rows.take(24).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(
              AppColors.background.withValues(alpha: 0.95),
            ),
            dataRowMinHeight: 54,
            dataRowMaxHeight: 62,
            headingTextStyle: const TextStyle(
              color: AppColors.foreground,
              fontWeight: FontWeight.w800,
            ),
            columns: [
              const DataColumn(label: Text('Producto')),
              const DataColumn(label: Text('Categoría')),
              const DataColumn(numeric: true, label: Text('Cantidad')),
              const DataColumn(numeric: true, label: Text('Proy. mes')),
              _moneyColumn('Brutas'),
              _moneyColumn('Descuentos'),
              _moneyColumn('Cortesías'),
              _moneyColumn('Netas'),
              _moneyColumn('Costo'),
              _moneyColumn('Gan. bruta'),
            ],
            rows: [
              for (final row in visibleRows)
                DataRow(
                  cells: [
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                            minWidth: 180, maxWidth: 260),
                        child: Text(row.product,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                    DataCell(Text(row.category)),
                    DataCell(
                        Text(row.quantitySold.toStringAsFixed(2))),
                    DataCell(
                      Text(
                        row.projectedQuantity > 0
                            ? row.projectedQuantity.toStringAsFixed(2)
                            : '-',
                        style: TextStyle(
                          color: row.projectedQuantity > 0
                              ? const Color(0xFF6B7280)
                              : AppColors.mutedForeground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    DataCell(Text(currency.format(row.grossSales))),
                    DataCell(Text(currency.format(row.discounts))),
                    DataCell(Text(currency.format(row.courtesies))),
                    DataCell(Text(currency.format(row.netSales))),
                    DataCell(Text(currency.format(row.cost))),
                    DataCell(
                      Text(
                        currency.format(row.grossProfit),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: row.grossProfit >= 0
                              ? const Color(0xFF047857)
                              : AppColors.destructive,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.itemGap),
        Container(
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(reportRadius),
            border: Border.all(color: AppColors.border),
          ),
          child: Wrap(
            spacing: AppSpacing.sectionGap,
            runSpacing: AppSpacing.itemGap,
            children: [
              ReportTotalPill(
                  label: 'Cantidad',
                  value:
                      (totals['quantity'] ?? 0).toStringAsFixed(2)),
              ReportTotalPill(
                  label: 'Proy. mes',
                  value:
                      (totals['projection'] ?? 0).toStringAsFixed(2)),
              ReportTotalPill(
                  label: 'Brutas',
                  value:
                      currency.format(totals['grossSales'] ?? 0)),
              ReportTotalPill(
                  label: 'Descuentos',
                  value:
                      currency.format(totals['discounts'] ?? 0)),
              ReportTotalPill(
                  label: 'Cortesías',
                  value:
                      currency.format(totals['courtesies'] ?? 0)),
              ReportTotalPill(
                  label: 'Netas',
                  value:
                      currency.format(totals['netSales'] ?? 0)),
              ReportTotalPill(
                  label: 'Costo',
                  value: currency.format(totals['cost'] ?? 0)),
              ReportTotalPill(
                  label: 'Gan. bruta',
                  value: currency
                      .format(totals['grossProfit'] ?? 0)),
            ],
          ),
        ),
        if (rows.length > visibleRows.length) ...[
          const SizedBox(height: AppSpacing.tightGap),
          Text(
            'Mostrando ${visibleRows.length} de ${rows.length} productos. La exportación incluye los filtros activos.',
            style: const TextStyle(
              color: AppColors.mutedForeground,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}
