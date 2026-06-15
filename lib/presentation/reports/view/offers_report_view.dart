import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/report_scaffold.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

/// Reporte "Ventas por oferta": ventas y cantidad de productos despachados
/// por cada oferta/promoción aplicada. Fuente de datos:
/// `order_items.promotion_id` agregado en [ReportsRepository.getOffersSummary].
class OffersReportView extends StatelessWidget {
  const OffersReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ReportScaffold(
      title: 'Ventas por oferta',
      category: ReportCategory.offers,
      body: (state, viewModel) =>
          _OffersReportBody(state: state, viewModel: viewModel),
    );
  }
}

class _OffersReportBody extends StatelessWidget {
  const _OffersReportBody({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = state.currency.formatter;
    final metrics = viewModel.getOffersMetricCards();
    final rows = viewModel.getOfferSalesRows();

    final totalNet =
        (state.offersSummary?['total_net'] as num?)?.toDouble() ?? 0;
    final totalQuantity =
        (state.offersSummary?['total_quantity'] as num?)?.toDouble() ?? 0;

    // Filas para el gráfico: ventas netas por oferta (top 8 las toma el card).
    final chartRows = rows
        .map(
          (row) => SalesBreakdownRow(
            label: row.name,
            amount: row.netSales,
            quantity: row.quantity,
            count: row.tickets,
          ),
        )
        .toList(growable: false);

    return ListView(
      padding: reportBodyPadding(context),
      children: [
        ReportHeroCard(
          title: 'Ventas por oferta',
          subtitle:
              'Cuánto vendió cada oferta o promoción y cuántos productos '
              'salieron con ella en el período seleccionado.',
          period: formatReportPeriod(state),
          accentColor: const Color(0xFFD946A6),
          trailing: [
            ReportHeroStat(
              label: 'Ventas en ofertas',
              value: currency.format(totalNet),
            ),
            ReportHeroStat(
              label: 'Productos despachados',
              value: NumberFormat('#,##0.##', 'en_US').format(totalQuantity),
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
          title: 'Ventas netas por oferta',
          rows: chartRows,
          color: const Color(0xFFD946A6),
        ),
        const SizedBox(height: AppSpacing.sectionGap),
        const ReportSectionLabel(
          title: 'Detalle por oferta',
          subtitle:
              'Cantidad de productos despachados, ventas y descuento '
              'otorgado por cada oferta.',
        ),
        const SizedBox(height: AppSpacing.itemGap),
        if (rows.isEmpty)
          const ReportSurfaceCard(
            child: ReportEmptyPlaceholder(
              icon: Icons.local_offer_outlined,
              message:
                  'No se registraron ventas con ofertas en el rango seleccionado.',
            ),
          )
        else
          _OffersTable(
            rows: rows,
            currency: currency,
            viewModel: viewModel,
          ),
      ],
    );
  }
}

class _OffersTable extends StatelessWidget {
  const _OffersTable({
    required this.rows,
    required this.currency,
    required this.viewModel,
  });

  final List<OfferSalesReportRow> rows;
  final NumberFormat currency;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final qtyFormat = NumberFormat('#,##0.##', 'en_US');
    final isMobile = ResponsiveHelper.isMobile(context);

    return ReportSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Encabezado de la tabla.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const Expanded(
                  flex: 4,
                  child: Text(
                    'Oferta',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ),
                _headerCell('Productos'),
                if (!isMobile) _headerCell('Tickets'),
                _headerCell('Descuento'),
                _headerCell('Ventas'),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.6)),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: rows.length,
            separatorBuilder: (_, _) =>
                Divider(height: 1, color: AppColors.border.withValues(alpha: 0.4)),
            itemBuilder: (context, index) {
              final row = rows[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      flex: 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.foreground,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            viewModel.offerTypeLabel(row.promoType),
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppColors.mutedForeground,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _valueCell(qtyFormat.format(row.quantity)),
                    if (!isMobile) _valueCell('${row.tickets}'),
                    _valueCell(
                      currency.format(row.discounts),
                      color: const Color(0xFFDC2626),
                    ),
                    _valueCell(
                      currency.format(row.netSales),
                      bold: true,
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  static Widget _headerCell(String label) {
    return Expanded(
      flex: 2,
      child: Text(
        label,
        textAlign: TextAlign.end,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
          color: AppColors.mutedForeground,
        ),
      ),
    );
  }

  static Widget _valueCell(String value, {bool bold = false, Color? color}) {
    return Expanded(
      flex: 2,
      child: Text(
        value,
        textAlign: TextAlign.end,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
          fontSize: 13,
          color: color ?? AppColors.foreground,
        ),
      ),
    );
  }
}
