import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/report_scaffold.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

const Color _kDeliveryAccent = Color(0xFF16A34A);

/// Reporte "Delivery": fees de delivery propio cobrados en el período —
/// lo que el negocio le paga/liquida al repartidor. Una fila por orden
/// cobrada con fee (Fecha de cobro · Cliente · Total orden · Fee), más el
/// total del período. Fuente: [ReportsRepository.getDeliveryFeesSummary].
class DeliveryReportView extends StatelessWidget {
  const DeliveryReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ReportScaffold(
      title: 'Delivery',
      category: ReportCategory.delivery,
      body: (state, viewModel) =>
          _DeliveryReportBody(state: state, viewModel: viewModel),
    );
  }
}

class _DeliveryReportBody extends StatelessWidget {
  const _DeliveryReportBody({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = state.currency.formatter;
    final numberFormat = NumberFormat('#,##0', 'en_US');
    final rows = viewModel.getDeliveryFeeRows();
    final ordersCount = viewModel.deliveryOrdersCount;
    final avgFee =
        ordersCount > 0 ? viewModel.deliveryTotalFees / ordersCount : 0.0;

    return ListView(
      padding: reportBodyPadding(context),
      children: [
        ReportHeroCard(
          title: 'Delivery',
          subtitle:
              'Fees de delivery cobrados en órdenes de delivery propio: cada '
              'orden con su fee y el total del período (lo que se liquida al '
              'repartidor).',
          period: formatReportPeriod(state),
          accentColor: _kDeliveryAccent,
          trailing: [
            ReportHeroStat(
              label: 'Total en fees',
              value: currency.format(viewModel.deliveryTotalFees),
            ),
            ReportHeroStat(
              label: 'Órdenes con delivery',
              value: numberFormat.format(ordersCount),
            ),
            ReportHeroStat(
              label: 'Fee promedio',
              value: currency.format(avgFee),
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
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xl),
            child: const ReportSurfaceCard(
              child: ReportEmptyPlaceholder(
                icon: Icons.delivery_dining_outlined,
                message:
                    'No se cobraron órdenes con fee de delivery en el rango '
                    'seleccionado.',
              ),
            ),
          )
        else ...[
          const SizedBox(height: AppSpacing.sectionGap),
          const ReportSectionLabel(
            title: 'Detalle por orden',
            subtitle: 'Una fila por cada orden cobrada con fee de delivery.',
          ),
          const SizedBox(height: AppSpacing.itemGap),
          _DeliveryDetailTable(rows: rows, currency: currency),
        ],
      ],
    );
  }
}

/// Listado detallado: Fecha de cobro · Cliente · Total orden · Fee.
class _DeliveryDetailTable extends StatelessWidget {
  const _DeliveryDetailTable({required this.rows, required this.currency});

  final List<DeliveryFeeLine> rows;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final isMobile = ResponsiveHelper.isMobile(context);
    final dateFormat =
        DateFormat(isMobile ? 'dd/MM HH:mm' : 'dd/MM/yyyy HH:mm:ss');
    final totalOrders = rows.fold<double>(0, (s, r) => s + r.orderTotal);
    final totalFees = rows.fold<double>(0, (s, r) => s + r.deliveryFee);

    // En teléfono la fila se aplasta; cada orden se muestra como tarjeta
    // apilada, con una tarjeta de totales al final (mismo patrón que el
    // reporte de ofertas).
    if (isMobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...rows.map(
            (row) => ReportRecordCard(
              title: row.customerName,
              fields: [
                ReportRecordField(
                  'Fecha de cobro',
                  row.paidAt != null ? dateFormat.format(row.paidAt!) : '—',
                ),
                ReportRecordField('Total orden', currency.format(row.orderTotal)),
                ReportRecordField(
                  'Fee de delivery',
                  currency.format(row.deliveryFee),
                  emphasize: true,
                ),
              ],
            ),
          ),
          ReportRecordCard(
            title: 'Total',
            highlight: true,
            fields: [
              ReportRecordField('Órdenes', '${rows.length}'),
              ReportRecordField('Total órdenes', currency.format(totalOrders)),
              ReportRecordField(
                'Total en fees',
                currency.format(totalFees),
                emphasize: true,
              ),
            ],
          ),
        ],
      );
    }

    return ReportSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                _headerCell('Fecha de cobro', flex: 3),
                _headerCell('Cliente', flex: 4),
                _headerCell('Total orden', flex: 2, end: true),
                _headerCell('Fee de delivery', flex: 2, end: true),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.6)),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: rows.length,
            separatorBuilder: (_, _) => Divider(
                height: 1, color: AppColors.border.withValues(alpha: 0.4)),
            itemBuilder: (context, index) {
              final row = rows[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _textCell(
                      row.paidAt != null ? dateFormat.format(row.paidAt!) : '—',
                      flex: 3,
                      muted: true,
                    ),
                    _textCell(row.customerName, flex: 4, bold: true),
                    _textCell(
                      currency.format(row.orderTotal),
                      flex: 2,
                      end: true,
                    ),
                    _textCell(
                      currency.format(row.deliveryFee),
                      flex: 2,
                      end: true,
                      bold: true,
                    ),
                  ],
                ),
              );
            },
          ),
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.6)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Expanded(
                  flex: 7,
                  child: Text(
                    'Total (${rows.length} órdenes)',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
                _totalCell(currency.format(totalOrders), flex: 2),
                _totalCell(currency.format(totalFees), flex: 2),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _totalCell(String value, {required int flex}) {
    return Expanded(
      flex: flex,
      child: Text(
        value,
        textAlign: TextAlign.end,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 13.5,
          color: AppColors.foreground,
        ),
      ),
    );
  }

  static Widget _headerCell(String label, {required int flex, bool end = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        label,
        textAlign: end ? TextAlign.end : TextAlign.start,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
          color: AppColors.mutedForeground,
        ),
      ),
    );
  }

  static Widget _textCell(
    String value, {
    required int flex,
    bool end = false,
    bool bold = false,
    bool muted = false,
  }) {
    return Expanded(
      flex: flex,
      child: Text(
        value,
        textAlign: end ? TextAlign.end : TextAlign.start,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          fontSize: 12.5,
          color: muted ? AppColors.mutedForeground : AppColors.foreground,
        ),
      ),
    );
  }
}
