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
    final currency = state.currency.formatter;

    // All data comes from fiscal_documents
    final fs = state.fiscalSummary ?? const <String, dynamic>{};
    final selectedType = state.fiscalTypeFilter;
    final availableTypes = viewModel.getAvailableFiscalTypes();

    // When a type filter is active, pull totals from the matching by_type bucket
    final byTypeList = (fs['by_type'] as List?) ?? const [];
    final activeTypeBucket = selectedType != null
        ? byTypeList
            .cast<Map>()
            .where((r) => r['ncf_type']?.toString() == selectedType)
            .cast<Map<String, dynamic>>()
            .firstOrNull
        : null;

    final totalItbis = activeTypeBucket != null
        ? (activeTypeBucket['itbis'] as num?)?.toDouble() ?? 0
        : (fs['total_itbis'] as num?)?.toDouble() ?? 0;
    final totalServiceFee = activeTypeBucket != null
        ? (activeTypeBucket['service_fee'] as num?)?.toDouble() ?? 0
        : (fs['total_service_fee'] as num?)?.toDouble() ?? 0;
    final totalSubtotal = activeTypeBucket != null
        ? (activeTypeBucket['subtotal'] as num?)?.toDouble() ?? 0
        : (fs['total_subtotal'] as num?)?.toDouble() ?? 0;
    final totalAmount = activeTypeBucket != null
        ? (activeTypeBucket['amount'] as num?)?.toDouble() ?? 0
        : (fs['total_amount'] as num?)?.toDouble() ?? 0;
    final activeCount = activeTypeBucket != null
        ? (activeTypeBucket['count'] as num?)?.toInt() ?? 0
        : (fs['active_count'] as num?)?.toInt() ?? 0;
    final voidCount =
        activeTypeBucket != null ? 0 : (fs['void_count'] as num?)?.toInt() ?? 0;

    final typeRows = viewModel.getFiscalTypeRows();
    final serviceFeeLabel =
        fs['service_fee_label']?.toString() ?? 'Propina de ley';
    final serviceFeeRate =
        (fs['service_fee_rate'] as num?)?.toDouble() ?? 0;
    final serviceFeeRateStr = serviceFeeRate > 0
        ? ' (${serviceFeeRate == serviceFeeRate.truncateToDouble() ? serviceFeeRate.toInt() : serviceFeeRate.toStringAsFixed(2)}%)'
        : '';

    return ListView(
      padding: reportBodyPadding(context),
      children: [
        // Hero card
        ReportHeroCard(
          title: 'Reporte de Impuestos',
          subtitle:
              'Basado en comprobantes fiscales emitidos. Fuente oficial para DGII.',
          accentColor: MangoColors.primaryOrange,
          trailing: [
            ReportHeroStat(
              label: 'Comprobantes activos',
              value: '$activeCount',
            ),
            ReportHeroStat(
              label: 'Total ITBIS',
              value: currency.format(totalItbis),
            ),
          ],
        ),

        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(state.error!,
              style: const TextStyle(color: AppColors.destructive)),
        ],

        const SizedBox(height: AppSpacing.xl),

        // NCF type filter chips
        if (availableTypes.isNotEmpty)
          ReportSurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ReportSectionLabel(
                  title: 'Filtrar por tipo de comprobante',
                  subtitle: 'Los totales se actualizan al seleccionar un tipo.',
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
                        label: type,
                        selected: selectedType == type,
                        onTap: () => viewModel.setFiscalTypeFilter(type),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

        const SizedBox(height: AppSpacing.itemGap),

        // Summary metrics
        Wrap(
          spacing: AppSpacing.itemGap,
          runSpacing: AppSpacing.itemGap,
          children: [
            _TaxMetricTile(
              label: 'ITBIS cobrado',
              value: currency.format(totalItbis),
              subtitle: '18% sobre base gravable',
              color: const Color(0xFF2563EB),
              icon: Icons.account_balance_outlined,
            ),
            _TaxMetricTile(
              label: 'Propina de ley',
              value: currency.format(totalServiceFee),
              subtitle: 'Cargo de servicio',
              color: const Color(0xFFF97316),
              icon: Icons.room_service_outlined,
            ),
            _TaxMetricTile(
              label: 'Base gravable',
              value: currency.format(totalSubtotal),
              subtitle: 'Subtotal antes de impuestos',
              color: const Color(0xFF7C3AED),
              icon: Icons.sell_outlined,
            ),
            _TaxMetricTile(
              label: 'Total facturado',
              value: currency.format(totalAmount),
              subtitle: 'Incluyendo impuestos',
              color: const Color(0xFF059669),
              icon: Icons.receipt_long_outlined,
            ),
            _TaxMetricTile(
              label: 'Anulados',
              value: '$voidCount',
              subtitle: 'Comprobantes anulados',
              color: const Color(0xFFDC2626),
              icon: Icons.cancel_outlined,
            ),
          ],
        ),

        const SizedBox(height: AppSpacing.sectionGap),

        // Chart by NCF type
        if (typeRows.isNotEmpty)
          ReportChartCard(
            title: 'Total facturado por tipo de comprobante',
            rows: typeRows,
            color: MangoColors.primaryOrange,
          ),

        const SizedBox(height: AppSpacing.itemGap),

        // NCF type breakdown table
        ReportSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ReportSectionLabel(
                title: 'Desglose por tipo de comprobante',
                subtitle:
                    'Total facturado e ITBIS agrupado por tipo NCF.',
              ),
              const SizedBox(height: AppSpacing.lg),
              if (typeRows.isEmpty)
                const ReportEmptyPlaceholder(
                  icon: Icons.description_outlined,
                  message: 'No hay comprobantes fiscales en el rango.',
                )
              else ...[
                // Header
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: const [
                      Expanded(
                          flex: 3,
                          child: _ColHeader('Tipo NCF')),
                      Expanded(
                          flex: 2,
                          child: _ColHeader('Comprobantes',
                              align: TextAlign.center)),
                      Expanded(
                          flex: 2,
                          child: _ColHeader('ITBIS',
                              align: TextAlign.right)),
                      Expanded(
                          flex: 2,
                          child: _ColHeader('Total',
                              align: TextAlign.right)),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ...typeRows.map(
                  (row) => Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: const BoxDecoration(
                      border: Border(
                          bottom: BorderSide(color: MangoColors.cardBorder)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text(
                            row.label,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            '${row.count}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: MangoColors.muted),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            currency.format(row.quantity),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                color: Color(0xFF2563EB),
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            currency.format(row.amount),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Totals row
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  color: MangoColors.sidebarBg.withValues(alpha: 0.4),
                  child: Row(
                    children: [
                      const Expanded(
                        flex: 3,
                        child: Text('TOTAL',
                            style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          '$activeCount',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          currency.format(totalItbis),
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              color: Color(0xFF2563EB),
                              fontWeight: FontWeight.w800),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          currency.format(totalAmount),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: AppSpacing.itemGap),

        // Tax type breakdown — ITBIS and service fee as separate explicit rows
        ReportSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ReportSectionLabel(
                title: 'Desglose por tipo de impuesto',
                subtitle:
                    'ITBIS y propina de ley leídos directamente de los comprobantes fiscales.',
              ),
              const SizedBox(height: AppSpacing.lg),
              if (totalItbis == 0 && totalServiceFee == 0)
                const ReportEmptyPlaceholder(
                  icon: Icons.receipt_outlined,
                  message: 'No hay impuestos registrados en el rango.',
                )
              else ...[
                // Header
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: const [
                      Expanded(flex: 3, child: _ColHeader('Concepto')),
                      Expanded(flex: 2, child: _ColHeader('Base gravable', align: TextAlign.right)),
                      Expanded(flex: 2, child: _ColHeader('Monto', align: TextAlign.right)),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (totalItbis > 0)
                  _TaxBreakdownRow(
                    label: 'ITBIS (18%)',
                    base: totalSubtotal,
                    amount: totalItbis,
                    color: const Color(0xFF2563EB),
                    currency: currency,
                  ),
                if (totalServiceFee > 0)
                  _TaxBreakdownRow(
                    label: '$serviceFeeLabel$serviceFeeRateStr',
                    base: totalSubtotal,
                    amount: totalServiceFee,
                    color: const Color(0xFFF97316),
                    currency: currency,
                  ),
                // Total row
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  color: MangoColors.sidebarBg.withValues(alpha: 0.4),
                  child: Row(
                    children: [
                      const Expanded(
                        flex: 3,
                        child: Text('TOTAL IMPUESTOS',
                            style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      const Expanded(flex: 2, child: SizedBox()),
                      Expanded(
                        flex: 2,
                        child: Text(
                          currency.format(totalItbis + totalServiceFee),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: AppSpacing.sectionGap),
      ],
    );
  }
}

class _TaxMetricTile extends StatelessWidget {
  final String label;
  final String value;
  final String subtitle;
  final Color color;
  final IconData icon;

  const _TaxMetricTile({
    required this.label,
    required this.value,
    required this.subtitle,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: color),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 11, color: MangoColors.muted),
          ),
        ],
      ),
    );
  }
}

class _TaxBreakdownRow extends StatelessWidget {
  final String label;
  final double base;
  final double amount;
  final Color color;
  final NumberFormat currency;

  const _TaxBreakdownRow({
    required this.label,
    required this.base,
    required this.amount,
    required this.color,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: MangoColors.cardBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                Text(label,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              currency.format(base),
              textAlign: TextAlign.right,
              style: const TextStyle(color: MangoColors.muted),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              currency.format(amount),
              textAlign: TextAlign.right,
              style: TextStyle(fontWeight: FontWeight.w800, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColHeader extends StatelessWidget {
  final String text;
  final TextAlign align;
  const _ColHeader(this.text, {this.align = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: align,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: MangoColors.muted,
      ),
    );
  }
}
