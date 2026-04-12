import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
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

  static String _ncfTypeName(String type) {
    switch (type) {
      case 'B01':
      case 'E31':
        return 'Crédito Fiscal';
      case 'B02':
      case 'E32':
        return 'Consumo';
      case 'B03':
      case 'E33':
        return 'Nota de Débito';
      case 'B04':
      case 'E34':
        return 'Nota de Crédito';
      case 'B14':
      case 'E44':
        return 'Reg. Especiales';
      case 'B15':
      case 'E45':
        return 'Gubernamental';
      default:
        return type;
    }
  }

  static List<String> _collectTaxLabels(
      List<Map<String, dynamic>> documents) {
    final labels = <String>{};
    for (final doc in documents) {
      final breakdown = doc['tax_breakdown'];
      if (breakdown is List) {
        for (final item in breakdown) {
          final row = item is Map<String, dynamic>
              ? item
              : Map<String, dynamic>.from(item as Map);
          final label = row['label']?.toString() ?? '';
          final rate = (row['rate'] as num?)?.toDouble() ?? 0;
          final display = rate > 0
              ? '$label (${rate.toStringAsFixed(rate.truncateToDouble() == rate ? 0 : 2)}%)'
              : label;
          if (display.isNotEmpty) labels.add(display);
        }
      }
      if (((doc['service_fee'] as num?)?.toDouble() ?? 0) > 0) {
        labels.add('Propina de ley');
      }
    }
    return labels.toList(growable: false);
  }

  static double _taxAmountForLabel(Map<String, dynamic> doc, String label) {
    if (label == 'Propina de ley') {
      return (doc['service_fee'] as num?)?.toDouble() ?? 0;
    }
    final breakdown = doc['tax_breakdown'];
    if (breakdown is! List) return 0;
    for (final item in breakdown) {
      final row = item is Map<String, dynamic>
          ? item
          : Map<String, dynamic>.from(item as Map);
      final itemLabel = row['label']?.toString() ?? '';
      final rate = (row['rate'] as num?)?.toDouble() ?? 0;
      final display = rate > 0
          ? '$itemLabel (${rate.toStringAsFixed(rate.truncateToDouble() == rate ? 0 : 2)}%)'
          : itemLabel;
      if (display == label) {
        return (row['tax_amount'] as num?)?.toDouble() ?? 0;
      }
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final dateFormat = DateFormat('dd/MM/yyyy hh:mm a');
    final metrics = viewModel.getFiscalMetricCards();
    final typeRows = viewModel.getFiscalTypeRows();
    final taxBreakdownRows = viewModel.getFiscalTaxBreakdownRows();
    final documents = viewModel.getFilteredFiscalDocuments();
    final availableTypes = viewModel.getAvailableFiscalTypes();
    final taxLabels = _collectTaxLabels(documents);
    final selectedType = state.fiscalTypeFilter;

    return ListView(
      padding: reportSectionPadding,
      children: [
        ReportHeroCard(
          title: 'Ventas por recibo / comprobante',
          subtitle:
              'Diseño listo para operar por rango de fecha y tipo de comprobante como filtros de primer nivel.',
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
                  : _ncfTypeName(selectedType),
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
                      label: _ncfTypeName(type),
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
        ReportSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ReportSectionLabel(
                title: 'Detalle de comprobantes',
                subtitle:
                    'Tabla lista para auditoría diaria y exportación; respeta el filtro de tipo seleccionado.',
              ),
              const SizedBox(height: AppSpacing.lg),
              if (documents.isEmpty)
                const ReportEmptyPlaceholder(
                  icon: Icons.description_outlined,
                  message:
                      'No hay comprobantes fiscales en el rango seleccionado.',
                )
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowColor: WidgetStateProperty.all(
                      MangoColors.bgLight,
                    ),
                    headingTextStyle: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                      fontSize: 12,
                    ),
                    dataRowMinHeight: 44,
                    dataRowMaxHeight: 58,
                    columnSpacing: 20,
                    horizontalMargin: 12,
                    columns: [
                      const DataColumn(label: Text('NCF')),
                      const DataColumn(label: Text('Tipo')),
                      const DataColumn(label: Text('Cliente')),
                      const DataColumn(label: Text('RNC/Cédula')),
                      const DataColumn(
                          label: Text('Subtotal'), numeric: true),
                      ...taxLabels.map(
                        (label) => DataColumn(
                            label: Text(label), numeric: true),
                      ),
                      const DataColumn(
                          label: Text('Total'), numeric: true),
                      const DataColumn(label: Text('Estado')),
                      const DataColumn(label: Text('Fecha')),
                    ],
                    rows: documents.map((doc) {
                      final ncfNumber =
                          doc['ncf_number']?.toString() ?? '';
                      final ncfType =
                          doc['ncf_type']?.toString() ?? '';
                      final customerName =
                          doc['customer_name']?.toString() ??
                              'CONSUMIDOR FINAL';
                      final customerRnc =
                          doc['customer_rnc']?.toString() ?? '-';
                      final subtotal =
                          (doc['subtotal'] as num?)?.toDouble() ?? 0;
                      final total =
                          (doc['total'] as num?)?.toDouble() ?? 0;
                      final status =
                          doc['status']?.toString() ?? 'active';
                      final issuedAt = DateTime.tryParse(
                              doc['issued_at']?.toString() ?? '') ??
                          DateTime.now();
                      final isVoid = status != 'active';

                      return DataRow(
                        color: isVoid
                            ? WidgetStateProperty.all(
                                AppColors.destructive
                                    .withValues(alpha: 0.04),
                              )
                            : null,
                        cells: [
                          DataCell(
                            Text(
                              ncfNumber,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          DataCell(Text(_ncfTypeName(ncfType))),
                          DataCell(
                            ConstrainedBox(
                              constraints:
                                  const BoxConstraints(maxWidth: 180),
                              child: Text(
                                customerName,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(
                            Text(customerRnc.isEmpty
                                ? '-'
                                : customerRnc),
                          ),
                          DataCell(Text(currency.format(subtotal))),
                          ...taxLabels.map(
                            (label) => DataCell(
                              Text(
                                _taxAmountForLabel(doc, label) > 0
                                    ? currency.format(
                                        _taxAmountForLabel(
                                            doc, label),
                                      )
                                    : '-',
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              currency.format(total),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          DataCell(
                            ReportStatusTag(
                              label: isVoid ? 'Anulado' : 'Activo',
                              tone: isVoid
                                  ? AppColors.destructive
                                  : MangoColors.successGreen,
                            ),
                          ),
                          DataCell(Text(
                              dateFormat.format(issuedAt.toLocal()))),
                        ],
                      );
                    }).toList(),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
