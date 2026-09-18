import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_shadows.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/presentation/reports/model/report_column.dart';
import 'package:mangopos/presentation/reports/model/report_table_data.dart';
import 'package:mangopos/presentation/reports/services/reports_csv_export_service.dart';
import 'package:mangopos/presentation/reports/services/reports_export_service.dart';
import 'package:mangopos/presentation/reports/state/report_view_preferences.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/column_picker_panel.dart';
import 'package:mangopos/presentation/reports/widgets/customizable_report_table.dart';
import 'package:mangopos/presentation/reports/widgets/report_scaffold.dart';
import 'package:mangopos/presentation/reports/widgets/report_table_toolbar.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

class SalesReportView extends StatelessWidget {
  const SalesReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ReportScaffold(
      title: 'Informe de ventas',
      category: ReportCategory.sales,
      // La pantalla trae su propio botón Exportar y muestra el rango en la
      // barra de acciones de la tabla.
      showExportButtons: false,
      showRangeSummary: false,
      subtitle: (state, viewModel) =>
          _SalesReportSubtitle(state: state, viewModel: viewModel),
      body: (state, viewModel) =>
          _SalesReportBody(state: state, viewModel: viewModel),
    );
  }
}

// ---------------------------------------------------------------------------
// Qué tabla corresponde a cada sub-reporte
// ---------------------------------------------------------------------------

class _TableMeta {
  const _TableMeta({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.emptyText,
    required this.source,
    this.labels,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final String emptyText;

  /// Función de origen, en monoespaciada en el selector de tipo.
  final String source;

  /// Rótulos del desglose (null en producto y en el detalle por comprobante).
  final BreakdownLabels? labels;
}

const Map<SalesSubReport, _TableMeta> _tableMeta = {
  SalesSubReport.byProduct: _TableMeta(
    title: 'Ventas por producto',
    subtitle:
        'Unidades, descuentos, costo y ganancia por producto en el rango.',
    icon: Icons.inventory_2_outlined,
    color: MangoColors.primaryOrange,
    emptyText:
        'No hay productos que coincidan con los filtros del rango seleccionado.',
    source: 'getFilteredProductSalesRows()',
  ),
  SalesSubReport.byCategory: _TableMeta(
    title: 'Ventas por categoría',
    subtitle: 'Qué familias del menú están empujando la facturación.',
    icon: Icons.category_outlined,
    color: Color(0xFF2563EB),
    emptyText: 'No hay ventas por categoría en el rango.',
    source: 'getCategoryRows()',
    labels: BreakdownLabels(
      axis: 'Categoría',
      count: 'Tickets',
      amount: 'Ventas',
      unit: 'ticket',
      showQuantity: true,
    ),
  ),
  SalesSubReport.byEmployee: _TableMeta(
    title: 'Ventas por empleado',
    subtitle: 'Rendimiento comercial por colaborador asignado.',
    icon: Icons.person_outline,
    color: Color(0xFF7C3AED),
    emptyText: 'No hay ventas por empleado en el rango.',
    source: 'getEmployeeRows()',
    labels: BreakdownLabels(
      axis: 'Empleado',
      count: 'Órdenes',
      amount: 'Ventas',
      unit: 'orden',
      showQuantity: false,
    ),
  ),
  SalesSubReport.byPayment: _TableMeta(
    title: 'Ventas por tipo de pago',
    subtitle: 'Composición de ingresos por método de cobro.',
    icon: Icons.payments_outlined,
    color: Color(0xFF059669),
    emptyText: 'No hay pagos en el rango seleccionado.',
    source: 'getPaymentMethodRows()',
    labels: BreakdownLabels(
      axis: 'Método de pago',
      count: 'Pagos',
      amount: 'Cobrado',
      unit: 'pago',
      showQuantity: false,
    ),
  ),
  SalesSubReport.byReceipt: _TableMeta(
    title: 'Ventas por recibo / comprobante',
    subtitle:
        'Balance entre recibos estándar, divididos y comprobantes fiscales.',
    icon: Icons.receipt_long_outlined,
    color: Color(0xFFF97316),
    emptyText: 'No hay recibos o comprobantes en el rango.',
    source: 'getReceiptRows()',
    labels: BreakdownLabels(
      axis: 'Tipo de documento',
      count: 'Documentos',
      amount: 'Facturado',
      unit: 'documento',
      showQuantity: false,
    ),
  ),
  SalesSubReport.byModifiers: _TableMeta(
    title: 'Ventas por modificadores',
    subtitle: 'Adicionales que empujan el ticket promedio.',
    icon: Icons.tune_outlined,
    color: Color(0xFF0891B2),
    emptyText: 'No hay modificadores cobrados en el rango.',
    source: 'getModifierRows()',
    labels: BreakdownLabels(
      axis: 'Modificador',
      count: 'Aplicaciones',
      amount: 'Ingreso',
      unit: 'aplicación',
      showQuantity: true,
    ),
  ),
  SalesSubReport.byDiscounts: _TableMeta(
    title: 'Descuentos y cortesías',
    subtitle: 'Controla el impacto comercial de descuentos y concesiones.',
    icon: Icons.local_offer_outlined,
    color: Color(0xFFDC2626),
    emptyText: 'No hay descuentos ni cortesías aplicados.',
    source: 'getDiscountRows()',
    labels: BreakdownLabels(
      axis: 'Concepto',
      count: 'Líneas',
      amount: 'Impacto',
      unit: 'línea',
      showQuantity: true,
    ),
  ),
  SalesSubReport.byZone: _TableMeta(
    title: 'Ventas por zona',
    subtitle: 'Distribución de ingresos por zona del local.',
    icon: Icons.place_outlined,
    color: Color(0xFF0891B2),
    emptyText: 'No hay ventas por zona en el rango.',
    source: 'getZoneRows()',
    labels: BreakdownLabels(
      axis: 'Zona',
      count: 'Órdenes',
      amount: 'Ventas',
      unit: 'orden',
      showQuantity: false,
    ),
  ),
  SalesSubReport.byProductionArea: _TableMeta(
    title: 'Ventas por área de producción',
    subtitle:
        'Distribución de ingresos por área de despacho (cocina, bar, caja).',
    icon: Icons.soup_kitchen_outlined,
    color: Color(0xFFEA580C),
    emptyText: 'No hay ventas por área de producción en el rango.',
    source: 'getProductionAreaRows()',
    labels: BreakdownLabels(
      axis: 'Área de producción',
      count: 'Órdenes',
      amount: 'Ventas',
      unit: 'orden',
      showQuantity: true,
    ),
  ),
  SalesSubReport.byHour: _TableMeta(
    title: 'Ventas por hora',
    subtitle: 'Actividad de ventas por franja horaria.',
    icon: Icons.schedule_outlined,
    color: Color(0xFF7C3AED),
    emptyText: 'No hay actividad en el rango.',
    source: 'getHourlyRows()',
    labels: BreakdownLabels(
      axis: 'Franja horaria',
      count: 'Transacciones',
      amount: 'Ventas',
      unit: 'transacción',
      showQuantity: false,
    ),
  ),
  SalesSubReport.byOffer: _TableMeta(
    title: 'Ventas por oferta',
    subtitle: 'Ofertas, combos y promociones aplicadas en órdenes pagadas.',
    icon: Icons.sell_outlined,
    color: MangoColors.primaryOrange,
    emptyText: 'No hay ofertas aplicadas en el rango.',
    source: 'getOfferRows()',
    // `count` es `tickets` del resumen de ofertas: órdenes pagadas distintas.
    labels: BreakdownLabels(
      axis: 'Oferta',
      count: 'Órdenes',
      amount: 'Ventas',
      unit: 'orden',
      showQuantity: true,
    ),
  ),
};

const _TableMeta _documentsMeta = _TableMeta(
  title: 'Detalle por comprobante',
  subtitle: 'Cada comprobante por separado. Los anulados se listan pero no '
      'suman.',
  icon: Icons.description_outlined,
  color: Color(0xFFF97316),
  emptyText: 'No hay comprobantes en el rango seleccionado.',
  source: 'getVisibleFiscalDocuments()',
);

String _sourceOf(SalesSubReport sub) =>
    _tableMeta[sub]?.source ?? 'getSalesMetricCards()';

/// Claves de vista de un sub-reporte (el de comprobante tiene dos niveles).
List<String> _viewKeysFor(SalesSubReport sub) => sub == SalesSubReport.byReceipt
    ? const ['sales.byReceipt', 'sales.byReceipt.documents']
    : ['sales.${sub.name}'];

List<SalesBreakdownRow> _breakdownRows(
  SalesSubReport sub,
  ReportsViewModel viewModel,
) {
  switch (sub) {
    case SalesSubReport.byCategory:
      return viewModel.getCategoryRows();
    case SalesSubReport.byEmployee:
      return viewModel.getEmployeeRows();
    case SalesSubReport.byPayment:
      return viewModel.getPaymentMethodRows();
    case SalesSubReport.byReceipt:
      return viewModel.getReceiptRows();
    case SalesSubReport.byModifiers:
      return viewModel.getModifierRows();
    case SalesSubReport.byDiscounts:
      return viewModel.getDiscountRows();
    case SalesSubReport.byZone:
      return viewModel.getZoneRows();
    case SalesSubReport.byProductionArea:
      return viewModel.getProductionAreaRows();
    case SalesSubReport.byHour:
      return viewModel.getHourlyRows();
    case SalesSubReport.byOffer:
      return viewModel.getOfferRows();
    case SalesSubReport.overview:
    case SalesSubReport.byProduct:
      return const [];
  }
}

String _serviceFeeLabel(ReportsState state) {
  final raw = (state.fiscalSummary?['service_fee_label'] as String?)?.trim();
  return (raw?.isNotEmpty ?? false) ? raw! : 'Cargo de servicio';
}

/// Tabla lista para pintar/exportar: definición + filas crudas + notas.
class _SalesTable {
  const _SalesTable({
    required this.meta,
    required this.definition,
    required this.records,
    this.notes = const [],
  });

  final _TableMeta meta;
  final ReportDefinition definition;
  final List<ReportRecord> records;

  /// Notas al pie de la tabla y del export.
  final List<String> notes;
}

_SalesTable? _resolveSalesTable(
  SalesSubReport sub,
  ReportsState state,
  ReportsViewModel viewModel, {
  required bool receiptDetail,
}) {
  final meta = _tableMeta[sub];
  if (meta == null) return null;

  if (sub == SalesSubReport.byProduct) {
    final rows = viewModel.getFilteredProductSalesRows();
    final query = state.productSalesQuery.trim();
    final category = state.productSalesCategoryFilter;
    return _SalesTable(
      meta: meta,
      definition: ReportCatalog.productSales(),
      records: rows.map(ReportCatalog.productRecord).toList(growable: false),
      notes: [
        if (query.isNotEmpty || category != null)
          'Filtros activos: '
              '${[
            if (query.isNotEmpty) 'búsqueda "$query"',
            if (category != null) 'categoría $category',
          ].join(', ')}.',
      ],
    );
  }

  if (sub == SalesSubReport.byReceipt && receiptDetail) {
    final all = viewModel.getFiscalDocuments();
    final feeLabel = _serviceFeeLabel(state);
    // Catálogo de impuestos sobre TODO el rango: mostrar u ocultar anulados
    // no cambia las columnas disponibles.
    final taxLabels = ReportCatalog.documentTaxLabels(all, feeLabel);
    final voided =
        all.where(ReportsViewModel.isVoidedFiscalDocument).toList();
    final voidedAmount = voided.fold<double>(
        0, (sum, d) => sum + ((d['total'] as num?)?.toDouble() ?? 0));
    final amount = state.currency.formatter.format(voidedAmount);
    final count = voided.length;
    final noun = count == 1 ? '1 anulado' : '$count anulados';
    return _SalesTable(
      meta: _documentsMeta,
      definition: ReportCatalog.fiscalDocuments(
        taxLabels: taxLabels,
        serviceFeeLabel: feeLabel,
        hasServiceFee: ReportCatalog.documentsHaveServiceFee(all),
      ),
      records: [
        for (final doc in viewModel.getVisibleFiscalDocuments())
          ReportCatalog.documentRecord(
            doc,
            taxLabels: taxLabels,
            serviceFeeLabel: feeLabel,
          ),
      ],
      notes: [
        if (count > 0)
          state.showVoidedFiscalDocuments
              ? 'Hay $noun por $amount: se listan tachados y no suman a '
                  'subtotal, impuestos ni total.'
              : 'Hay $noun por $amount ocultos: no suman a subtotal, '
                  'impuestos ni total.',
      ],
    );
  }

  final labels = meta.labels!;
  return _SalesTable(
    meta: meta,
    definition: ReportCatalog.breakdown(
      key: 'sales.${sub.name}',
      title: meta.title,
      source: meta.source,
      labels: labels,
    ),
    records: [
      for (final row in _breakdownRows(sub, viewModel))
        ReportCatalog.breakdownRecord(row, showQuantity: labels.showQuantity),
    ],
  );
}

// ---------------------------------------------------------------------------
// Encabezado: "{n} columnas · {m} filas · {rango}"
// ---------------------------------------------------------------------------

class _SalesReportSubtitle extends ConsumerWidget {
  const _SalesReportSubtitle({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(reportViewPreferencesProvider);
    final range = formatReportPeriod(state);
    final source = _resolveSalesTable(
      state.salesSubReport,
      state,
      viewModel,
      receiptDetail: prefs.receiptDetail,
    );
    final text = source == null
        ? range
        : '${prefs.configFor(source.definition).columns.length} columnas · '
            '${source.records.length} filas · $range';
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.mutedForeground,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cuerpo
// ---------------------------------------------------------------------------

class _SalesReportBody extends ConsumerWidget {
  const _SalesReportBody({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  /// Cambiar de tipo restablece columnas y orden.
  void _selectSubReport(WidgetRef ref, SalesSubReport sub) {
    ref
        .read(reportViewPreferencesProvider.notifier)
        .resetReports(_viewKeysFor(sub));
    viewModel.setSalesSubReport(sub);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currency = state.currency.formatter;
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
    // F5: si el resumen viene del cache offline, mostramos un aviso de
    // frescura en vez de aparentar datos en vivo.
    final cachedAt = viewModel.salesDataCachedAt;
    // "Vista general" no es una tabla: exporta el informe completo (PDF/CSV
    // de siempre). Los tipos tabulares exportan desde su propia tabla.
    Widget overviewExport() => ReportExportMenuButton(
          headline: 'Informe de ventas',
          detail: 'Vista general · ${formatReportPeriod(state)}',
          formats: const [ReportExportFormat.pdf, ReportExportFormat.csv],
          onExport: (format) async {
            try {
              if (format == ReportExportFormat.pdf) {
                await ReportsExportService.exportCurrentReport(
                  category: ReportCategory.sales,
                  state: state,
                  viewModel: viewModel,
                );
              } else {
                await ReportsCsvExportService.exportCurrentReport(
                  category: ReportCategory.sales,
                  state: state,
                  viewModel: viewModel,
                );
              }
            } catch (_) {
              if (context.mounted) {
                AppToast.error(context, 'No se pudo exportar el informe.');
              }
            }
          },
        );
    final isOverview = selectedSub == SalesSubReport.overview;

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
        if (cachedAt != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          OfflineDataBanner(cachedAt: cachedAt),
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
                  if (isOverview && !isMobile) ...[
                    const SizedBox(width: AppSpacing.tightGap),
                    overviewExport(),
                  ],
                ],
              ),
              if (isOverview && isMobile) ...[
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerLeft, child: overviewExport()),
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
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  viewModel.salesSubReportLabel(sub),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                              if (!isMobile) ...[
                                const SizedBox(width: 12),
                                Text(
                                  _sourceOf(sub),
                                  style: const TextStyle(
                                    fontFamily: reportNumberFontFamily,
                                    fontSize: 11.5,
                                    color: AppColors.mutedForeground,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null && value != selectedSub) {
                          _selectSubReport(ref, value);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              _StatTiles(
                tiles: [
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
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sectionGap),
        buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        ..._buildSubReportContent(ref, selectedSub),
      ],
    );
  }

  List<Widget> _buildSubReportContent(WidgetRef ref, SalesSubReport sub) {
    if (sub == SalesSubReport.overview) {
      final methodRows = viewModel.getPaymentMethodRows();
      Widget preview(SalesSubReport target) => _BreakdownPreviewCard(
            sub: target,
            state: state,
            viewModel: viewModel,
            onViewAll: () => _selectSubReport(ref, target),
          );
      return [
        ReportChartCard(
          title: 'Distribución de ventas por pago',
          rows: methodRows,
          color: AppColors.primary,
        ),
        const Divider(color: AppColors.border),
        const SizedBox(height: AppSpacing.sectionGap),
        preview(SalesSubReport.byCategory),
        const SizedBox(height: AppSpacing.sectionGap),
        const Divider(color: AppColors.border),
        const SizedBox(height: AppSpacing.sectionGap),
        preview(SalesSubReport.byEmployee),
        const SizedBox(height: AppSpacing.sectionGap),
        const Divider(color: AppColors.border),
        const SizedBox(height: AppSpacing.sectionGap),
        preview(SalesSubReport.byPayment),
      ];
    }

    return [
      if (sub == SalesSubReport.byPayment) ...[
        ReportChartCard(
          title: 'Distribución de ventas por pago',
          rows: viewModel.getPaymentMethodRows(),
          color: AppColors.primary,
        ),
        const Divider(color: AppColors.border),
        const SizedBox(height: AppSpacing.sectionGap),
      ],
      if (sub == SalesSubReport.byHour) ...[
        ReportChartCard(
          title: 'Ventas por hora',
          rows: viewModel.getHourlyRows(),
          color: const Color(0xFF7C3AED),
        ),
        const Divider(color: AppColors.border),
        const SizedBox(height: AppSpacing.sectionGap),
      ],
      _CustomizableReportCard(sub: sub, state: state, viewModel: viewModel),
      if (sub == SalesSubReport.byCategory) ...[
        const SizedBox(height: AppSpacing.sectionGap),
        _CategoryProductBreakdownCard(
          breakdown: viewModel.getCategoryProductBreakdown(),
          currency: state.currency.formatter,
        ),
      ],
    ];
  }
}

// ---------------------------------------------------------------------------
// Tarjeta con la tabla personalizable
// ---------------------------------------------------------------------------

class _StatTiles extends StatelessWidget {
  const _StatTiles({required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < AppBreakpoints.tablet) {
          // stretch: en teléfono/tablet-angosto cada tile ocupa el ancho
          // completo en vez de su ancho intrínseco.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.tightGap),
                tiles[i],
              ],
            ],
          );
        }
        return Row(
          children: [
            for (var i = 0; i < tiles.length; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.tightGap),
              Expanded(child: tiles[i]),
            ],
          ],
        );
      },
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.meta, this.trailing});

  final _TableMeta meta;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: meta.color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(reportRadius),
          ),
          child: Icon(meta.icon, color: meta.color, size: 20),
        ),
        const SizedBox(width: AppSpacing.itemGap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                meta.title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                meta.subtitle,
                style: const TextStyle(
                  color: AppColors.mutedForeground,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

BoxDecoration _cardDecoration() => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(reportRadius),
      border: Border.all(color: AppColors.border),
      boxShadow: AppShadows.soft,
    );

/// Tiles de resumen de la tarjeta, calculados sobre TODAS las filas del
/// reporte (no dependen de las columnas visibles).
List<Widget> _summaryTiles(_SalesTable source, NumberFormat currency) {
  final numberFormat = NumberFormat('#,##0', 'en_US');
  final valid = source.records.where((r) => !r.excluded).toList();
  double sum(String field) =>
      valid.fold<double>(0, (total, r) => total + (r.number(field) ?? 0));

  if (source.definition.key == 'sales.byProduct') {
    return [
      CommercialStatTile(
        label: 'Productos visibles',
        value: '${source.records.length}',
        hint: 'Filtrados sobre el rango activo',
      ),
      CommercialStatTile(
        label: 'Unidades vendidas',
        value: NumberFormat('#,##0.##', 'en_US')
            .format(sum(ReportColumnIds.quantity)),
        hint: 'Cantidad consolidada',
      ),
      CommercialStatTile(
        label: 'Ventas netas',
        value: currency.format(sum(ReportColumnIds.amount)),
        hint: 'Después de descuentos y cortesías',
      ),
      CommercialStatTile(
        label: 'Ganancia bruta',
        value: currency.format(sum(ReportColumnIds.grossProfit)),
        hint: 'Netas menos costo actual del producto',
      ),
    ];
  }

  if (source.definition.key == 'sales.byReceipt.documents') {
    final excluded = source.records.where((r) => r.excluded).toList();
    return [
      CommercialStatTile(
        label: 'Comprobantes válidos',
        value: numberFormat.format(valid.length),
        hint: 'Listados en el rango',
      ),
      CommercialStatTile(
        label: 'Total facturado',
        value: currency.format(sum(ReportColumnIds.total)),
        hint: 'Solo comprobantes activos',
      ),
      CommercialStatTile(
        label: 'Subtotal',
        value: currency.format(sum(ReportColumnIds.subtotal)),
        hint: excluded.isEmpty
            ? 'Antes de impuestos'
            : excluded.length == 1
                ? '1 anulado listado, sin sumar'
                : '${excluded.length} anulados listados, sin sumar',
      ),
    ];
  }

  final labels = source.meta.labels!;
  final quantity = sum(ReportColumnIds.quantity);
  return [
    CommercialStatTile(
      label: labels.amount,
      value: currency.format(sum(ReportColumnIds.amount)),
      hint: 'Total acumulado',
    ),
    CommercialStatTile(
      label: labels.count,
      value: numberFormat.format(sum(ReportColumnIds.count)),
      hint: labels.showQuantity
          ? '${numberFormat.format(quantity)} unidades'
          : 'Movimientos registrados',
    ),
    CommercialStatTile(
      label: 'Líder',
      value: source.records.isEmpty
          ? 'Sin datos'
          : '${source.records.first[ReportColumnIds.label]}',
      hint: source.records.isEmpty ? 'Sin actividad' : 'Primer lugar',
    ),
  ];
}

class _CustomizableReportCard extends ConsumerWidget {
  const _CustomizableReportCard({
    required this.sub,
    required this.state,
    required this.viewModel,
  });

  final SalesSubReport sub;
  final ReportsState state;
  final ReportsViewModel viewModel;

  Future<void> _export(
    BuildContext context,
    _SalesTable source,
    ReportTableData table,
    ReportExportFormat format,
  ) async {
    final export = ReportTableExport(
      table: table,
      title: source.meta.title,
      from: state.salesFrom,
      to: state.salesTo.subtract(const Duration(days: 1)),
      currencyCode: state.currency.code,
      currencyDecimals: state.currency.decimalDigits,
      notes: source.notes,
    );
    try {
      await ReportsExportService.exportTable(export, format);
    } catch (_) {
      if (context.mounted) {
        AppToast.error(context, 'No se pudo exportar el reporte.');
      }
    }
  }

  Future<void> _openColumns(
    BuildContext context,
    WidgetRef ref,
    ReportDefinition definition,
    ReportViewConfig config,
  ) async {
    final columns = await showColumnPickerPanel(
      context,
      definition: definition,
      visible: config.columns,
    );
    if (columns == null) return;
    final notifier = ref.read(reportViewPreferencesProvider.notifier);
    notifier.setConfig(
      definition,
      ref
          .read(reportViewPreferencesProvider)
          .configFor(definition)
          .copyWith(columns: columns),
    );
  }

  Future<void> _saveView(
    BuildContext context,
    WidgetRef ref,
    ReportDefinition definition,
  ) async {
    final name = await showSaveReportViewDialog(
      context,
      reportTitle: definition.title,
    );
    if (name == null) return;
    await ref
        .read(reportViewPreferencesProvider.notifier)
        .saveCurrentView(definition, name);
    if (context.mounted) AppToast.success(context, 'Vista "$name" guardada.');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(reportViewPreferencesProvider);
    final notifier = ref.read(reportViewPreferencesProvider.notifier);
    final source = _resolveSalesTable(
      sub,
      state,
      viewModel,
      receiptDetail: prefs.receiptDetail,
    )!;
    final definition = source.definition;
    final config = prefs.configFor(definition);
    final table = buildReportTable(
      definition: definition,
      records: source.records,
      config: config,
      formats: ReportFormats(currency: state.currency.formatter),
    );
    final range = formatReportPeriod(state);
    final isMobile = ResponsiveHelper.isMobile(context);

    return Container(
      padding: EdgeInsets.all(isMobile ? 14 : AppSpacing.cardPadding),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardHeader(meta: source.meta),
          const SizedBox(height: AppSpacing.lg),
          _StatTiles(
            tiles: _summaryTiles(source, state.currency.formatter),
          ),
          const Divider(height: AppSpacing.sectionGap, color: AppColors.border),
          if (sub == SalesSubReport.byReceipt) ...[
            ReportLevelBar(
              detail: prefs.receiptDetail,
              onDetail: notifier.setReceiptDetail,
              showVoided: state.showVoidedFiscalDocuments,
              voidedCount: viewModel.getVoidedFiscalDocumentsCount(),
              onToggleVoided: viewModel.setShowVoidedFiscalDocuments,
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          ReportViewPresetBar(
            definition: definition,
            selectedViewId: prefs.selectedViewId(definition.key),
            modified: prefs.isModified(definition),
            savedViews: prefs.savedFor(definition.key),
            onSelect: (viewId) => notifier.applyView(definition, viewId),
            onSave: () => _saveView(context, ref, definition),
            onDelete: (view) => notifier.deleteView(definition, view.id),
          ),
          const SizedBox(height: AppSpacing.tightGap),
          ReportTableActionBar(
            rangeLabel: range,
            visibleColumns: table.columns.length,
            onColumns: () => _openColumns(context, ref, definition, config),
            density: prefs.density,
            onDensity: notifier.setDensity,
            groupableColumns: [
              for (final column in table.columns)
                if (column.groupable) column,
            ],
            groupBy: table.config.groupBy,
            onGroupBy: (columnId) => notifier.setGroupBy(definition, columnId),
            exportButton: ReportExportMenuButton(
              headline: source.meta.title,
              detail: '${table.columns.length} columnas · '
                  '${table.dataRowCount} filas · $range',
              onExport: (format) => _export(context, source, table, format),
            ),
          ),
          if (sub == SalesSubReport.byProduct) ...[
            const SizedBox(height: AppSpacing.itemGap),
            _ProductSalesFilters(state: state, viewModel: viewModel),
          ],
          const SizedBox(height: AppSpacing.itemGap),
          if (table.isEmpty)
            ReportEmptyPlaceholder(
              icon: source.meta.icon,
              message: source.meta.emptyText,
            )
          else
            CustomizableReportTable(
              table: table,
              density: prefs.density,
              onSort: (columnId) => notifier.toggleSort(definition, columnId),
            ),
          for (final note in source.notes)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.info_outline_rounded,
                        size: 15, color: AppColors.mutedForeground),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      note,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Vista previa de "Vista general": la misma tabla, con las columnas por
/// defecto y las 6 primeras filas.
class _BreakdownPreviewCard extends ConsumerWidget {
  const _BreakdownPreviewCard({
    required this.sub,
    required this.state,
    required this.viewModel,
    required this.onViewAll,
  });

  static const _previewRows = 6;

  final SalesSubReport sub;
  final ReportsState state;
  final ReportsViewModel viewModel;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final density = ref.watch(
      reportViewPreferencesProvider.select((prefs) => prefs.density),
    );
    final source =
        _resolveSalesTable(sub, state, viewModel, receiptDetail: false)!;
    final table = buildReportTable(
      definition: source.definition,
      records: source.records.take(_previewRows).toList(growable: false),
      config: source.definition.defaultConfig,
      formats: ReportFormats(currency: state.currency.formatter),
      totalLabel: 'Total mostrado',
    );
    final meta = source.meta;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardHeader(
            meta: meta,
            trailing: source.records.length > _previewRows
                ? TextButton.icon(
                    onPressed: onViewAll,
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: const Text('Ver todo'),
                    style: TextButton.styleFrom(
                      foregroundColor: meta.color,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                : null,
          ),
          const SizedBox(height: AppSpacing.lg),
          _StatTiles(
            tiles: _summaryTiles(source, state.currency.formatter),
          ),
          const Divider(height: AppSpacing.sectionGap, color: AppColors.border),
          if (table.isEmpty)
            ReportEmptyPlaceholder(icon: meta.icon, message: meta.emptyText)
          else
            CustomizableReportTable(table: table, density: density),
        ],
      ),
    );
  }
}

class _ProductSalesFilters extends StatelessWidget {
  const _ProductSalesFilters({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final categories = viewModel.getAvailableProductSalesCategories();
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < AppBreakpoints.tablet;
        final searchField = TextFormField(
          key: ValueKey('product-sales-query-${state.productSalesQuery}'),
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
              borderSide: const BorderSide(color: MangoColors.primaryOrange),
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
              borderSide: const BorderSide(color: MangoColors.primaryOrange),
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
              Align(alignment: Alignment.centerLeft, child: clearButton),
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
    );
  }
}

/// Desglose expandible: cada categoría con los productos que vendió en el
/// rango (cantidad, brutas, descuentos y netas por producto).
class _CategoryProductBreakdownCard extends StatelessWidget {
  const _CategoryProductBreakdownCard({
    required this.breakdown,
    required this.currency,
  });

  final List<CategoryProductBreakdown> breakdown;
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
                  color: const Color(0xFF2563EB).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(reportRadius),
                ),
                child: const Icon(
                  Icons.segment_outlined,
                  color: Color(0xFF2563EB),
                ),
              ),
              const SizedBox(width: AppSpacing.itemGap),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Desglose por categoría',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Toca una categoría para ver qué productos vendió en el rango.',
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
          if (breakdown.isEmpty)
            const Text(
              'No hay ventas por categoría en el rango.',
              style: TextStyle(color: AppColors.mutedForeground),
            )
          else
            ...breakdown.map(
              (group) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.tightGap),
                child: _CategoryBreakdownTile(
                  group: group,
                  currency: currency,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoryBreakdownTile extends StatelessWidget {
  const _CategoryBreakdownTile({
    required this.group,
    required this.currency,
  });

  final CategoryProductBreakdown group;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(reportRadius),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          // La flecha va al inicio porque `trailing` está ocupado por el
          // monto de la categoría.
          controlAffinity: ListTileControlAffinity.leading,
          tilePadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.cardPadding,
            vertical: 4,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(
            AppSpacing.cardPadding,
            0,
            AppSpacing.cardPadding,
            AppSpacing.cardPadding,
          ),
          title: Text(
            group.category,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
          subtitle: Text(
            '${group.products.length} producto${group.products.length == 1 ? '' : 's'} · ${group.quantitySold.toStringAsFixed(group.quantitySold == group.quantitySold.roundToDouble() ? 0 : 2)} unidades',
            style: const TextStyle(
              color: AppColors.mutedForeground,
              fontSize: 12,
            ),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                currency.format(group.netSales),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              if (group.discounts > 0)
                Text(
                  '-${currency.format(group.discounts)} desc.',
                  style: const TextStyle(
                    color: AppColors.destructive,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: MediaQuery.of(context).size.width -
                      4 * AppSpacing.cardPadding,
                ),
                child: DataTable(
                  headingRowHeight: 40,
                  dataRowMinHeight: 40,
                  dataRowMaxHeight: 48,
                  headingTextStyle: const TextStyle(
                    color: AppColors.mutedForeground,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                  columns: const [
                    DataColumn(label: Text('Producto')),
                    DataColumn(numeric: true, label: Text('Cantidad')),
                    DataColumn(numeric: true, label: Text('Brutas')),
                    DataColumn(numeric: true, label: Text('Descuentos')),
                    DataColumn(numeric: true, label: Text('Netas')),
                  ],
                  rows: [
                    for (final row in group.products)
                      DataRow(
                        cells: [
                          DataCell(
                            ConstrainedBox(
                              constraints: const BoxConstraints(
                                  minWidth: 140, maxWidth: 240),
                              child: Text(
                                row.product,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                          DataCell(Text(row.quantitySold.toStringAsFixed(
                              row.quantitySold ==
                                      row.quantitySold.roundToDouble()
                                  ? 0
                                  : 2))),
                          DataCell(Text(currency.format(row.grossSales))),
                          DataCell(
                            Text(
                              row.discounts > 0
                                  ? '-${currency.format(row.discounts)}'
                                  : '--',
                              style: TextStyle(
                                color: row.discounts > 0
                                    ? AppColors.destructive
                                    : AppColors.mutedForeground,
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              currency.format(row.netSales),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
