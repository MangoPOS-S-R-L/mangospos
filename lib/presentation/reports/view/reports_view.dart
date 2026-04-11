import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_shadows.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/presentation/reports/services/reports_csv_export_service.dart';
import 'package:mangopos/presentation/reports/services/reports_export_service.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

const double _reportRadius = 10.0;
const EdgeInsets _sectionPadding = EdgeInsets.fromLTRB(
  AppSpacing.containerPadding,
  0,
  AppSpacing.containerPadding,
  AppSpacing.containerPadding,
);

ButtonStyle _reportOutlineButtonStyle() {
  return OutlinedButton.styleFrom(
    foregroundColor: MangoColors.primaryOrange,
    backgroundColor: Colors.white,
    side: const BorderSide(color: MangoColors.primaryOrange),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_reportRadius),
    ),
    textStyle: const TextStyle(fontWeight: FontWeight.w700),
  );
}

class ReportsView extends ConsumerStatefulWidget {
  const ReportsView({super.key, this.initialCategory});

  final ReportCategory? initialCategory;

  @override
  ConsumerState<ReportsView> createState() => _ReportsViewState();
}

class _ReportsViewState extends ConsumerState<ReportsView> {
  String? _lastBusinessId;
  bool _appliedInitialCategory = false;

  void _syncCategoryFromRoute() {
    final viewModel = ref.read(reportsViewModelProvider.notifier);
    viewModel.selectCategory(widget.initialCategory);
  }

  void _handleBack(ReportsState state, ReportsViewModel viewModel) {
    if (state.selectedCategory == null) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(AppRoutes.dashboard);
      }
      return;
    }

    if (widget.initialCategory != null) {
      viewModel.selectCategory(null);
      context.go(AppRoutes.reports);
      return;
    }

    viewModel.selectCategory(null);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _appliedInitialCategory) return;
      _syncCategoryFromRoute();
      _appliedInitialCategory = true;
    });
  }

  @override
  void didUpdateWidget(covariant ReportsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialCategory != widget.initialCategory) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _syncCategoryFromRoute();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final state = ref.watch(reportsViewModelProvider);
    final viewModel = ref.read(reportsViewModelProvider.notifier);

    if (session.activeBusinessId != null &&
        session.activeBusinessId != _lastBusinessId) {
      _lastBusinessId = session.activeBusinessId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        viewModel.load();
      });
    }

    return PopScope(
      canPop: state.selectedCategory == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack(state, viewModel);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.containerPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: AppSpacing.lg),
                          child: IconButton(
                            icon: const Icon(
                              Icons.arrow_back,
                              color: AppColors.foreground,
                            ),
                            onPressed: () => _handleBack(state, viewModel),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            state.selectedCategory == null
                                ? 'Informes'
                                : viewModel.getCategoryTitle(
                                    state.selectedCategory!,
                                  ),
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: AppColors.foreground,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (state.loading)
                          Padding(
                            padding: const EdgeInsets.only(
                              right: AppSpacing.sm,
                            ),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: MangoColors.primaryOrange,
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: 'Actualizar',
                          onPressed: state.loading ? null : viewModel.load,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    if (state.selectedCategory == null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      const Text(
                        'Mira y analiza todos los números que genera tu negocio',
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: AppSpacing.itemGap),
                      _ReportsToolbar(
                        state: state,
                        viewModel: viewModel,
                        onExportPdf: () async {
                          await ReportsExportService.exportCurrentReport(
                            category: state.selectedCategory!,
                            state: state,
                            viewModel: viewModel,
                          );
                        },
                        onExportCsv: () async {
                          await ReportsCsvExportService.exportCurrentReport(
                            category: state.selectedCategory!,
                            state: state,
                            viewModel: viewModel,
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(child: _buildContent(context, state, viewModel)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    ReportsState state,
    ReportsViewModel viewModel,
  ) {
    if (state.loading && state.salesSummary == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: MangoColors.primaryOrange),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              'Cargando informes...',
              style: TextStyle(color: AppColors.mutedForeground, fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (state.error != null && state.selectedCategory == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.containerPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: AppColors.destructive.withValues(alpha: 0.7),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                state.error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.destructive,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              OutlinedButton.icon(
                style: _reportOutlineButtonStyle(),
                onPressed: viewModel.load,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.selectedCategory == ReportCategory.sales) {
      return _SalesReportSection(state: state, viewModel: viewModel);
    }
    if (state.selectedCategory == ReportCategory.finances) {
      return _FinanceReportSection(state: state, viewModel: viewModel);
    }
    if (state.selectedCategory == ReportCategory.inventory) {
      return _InventoryReportSection(state: state, viewModel: viewModel);
    }
    if (state.selectedCategory == ReportCategory.purchases) {
      return _PurchasesReportSection(state: state, viewModel: viewModel);
    }
    if (state.selectedCategory == ReportCategory.taxes) {
      return _TaxReportSection(state: state, viewModel: viewModel);
    }
    if (state.selectedCategory == ReportCategory.fiscal) {
      return _FiscalReportSection(state: state, viewModel: viewModel);
    }

    return state.selectedCategory == null
        ? _buildGrid(context, viewModel)
        : _buildReportList(context, viewModel, state.selectedCategory!);
  }

  Widget _buildGrid(BuildContext context, ReportsViewModel viewModel) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth >= AppBreakpoints.desktop
            ? 5
            : constraints.maxWidth >= AppBreakpoints.tablet
            ? 4
            : constraints.maxWidth >= AppBreakpoints.mobile
            ? 3
            : 2;
        return GridView.count(
          crossAxisCount: crossAxisCount,
          padding: const EdgeInsets.all(AppSpacing.sectionGap),
          mainAxisSpacing: AppSpacing.sectionGap,
          crossAxisSpacing: AppSpacing.sectionGap,
          childAspectRatio: 1.0,
          children: ReportCategory.values.map((category) {
            return _ReportCard(
              title: viewModel.getCategoryTitle(category),
              icon: viewModel.getCategoryIcon(category),
              onTap: () => viewModel.selectCategory(category),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildReportList(
    BuildContext context,
    ReportsViewModel viewModel,
    ReportCategory category,
  ) {
    final reports = viewModel.getReportsForCategory(category);

    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.containerPadding),
      itemCount: reports.length,
      separatorBuilder: (context, index) =>
          const SizedBox(height: AppSpacing.itemGap),
      itemBuilder: (context, index) {
        final report = reports[index];
        return _ReportListItem(
          title: report.title,
          description: report.description,
          onTap: report.onTap ?? () {},
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

class _ReportsToolbar extends StatelessWidget {
  const _ReportsToolbar({
    required this.state,
    required this.viewModel,
    required this.onExportPdf,
    required this.onExportCsv,
  });

  final ReportsState state;
  final ReportsViewModel viewModel;
  final Future<void> Function() onExportPdf;
  final Future<void> Function() onExportCsv;

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd MMM yyyy');
    final displayedTo = state.salesTo.subtract(const Duration(days: 1));

    return Wrap(
      spacing: AppSpacing.tightGap,
      runSpacing: AppSpacing.tightGap,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _RangeChip(
          label: 'Hoy',
          selected: state.salesRangePreset == SalesReportRangePreset.today,
          onTap: () => viewModel.setSalesPreset(SalesReportRangePreset.today),
        ),
        _RangeChip(
          label: 'Ayer',
          selected: state.salesRangePreset == SalesReportRangePreset.yesterday,
          onTap: () =>
              viewModel.setSalesPreset(SalesReportRangePreset.yesterday),
        ),
        _RangeChip(
          label: 'Esta semana',
          selected: state.salesRangePreset == SalesReportRangePreset.thisWeek,
          onTap: () =>
              viewModel.setSalesPreset(SalesReportRangePreset.thisWeek),
        ),
        _RangeChip(
          label: 'Este mes',
          selected: state.salesRangePreset == SalesReportRangePreset.thisMonth,
          onTap: () =>
              viewModel.setSalesPreset(SalesReportRangePreset.thisMonth),
        ),
        OutlinedButton.icon(
          style: _reportOutlineButtonStyle(),
          onPressed: () async {
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2024, 1, 1),
              lastDate: AppTime.nowAst().add(const Duration(days: 365)),
              initialDateRange: DateTimeRange(
                start: state.salesFrom,
                end: displayedTo,
              ),
            );
            if (picked == null) return;
            await viewModel.setCustomSalesRange(picked.start, picked.end);
          },
          icon: const Icon(Icons.date_range_outlined),
          label: const Text('Rango personalizado'),
        ),
        OutlinedButton.icon(
          style: _reportOutlineButtonStyle(),
          onPressed: onExportPdf,
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: const Text('PDF'),
        ),
        OutlinedButton.icon(
          style: _reportOutlineButtonStyle(),
          onPressed: onExportCsv,
          icon: const Icon(Icons.table_view_outlined),
          label: const Text('CSV'),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.secondary,
            borderRadius: BorderRadius.circular(_reportRadius),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.calendar_today,
                size: 14,
                color: AppColors.mutedForeground,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${dateFormat.format(state.salesFrom)} – ${dateFormat.format(displayedTo)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Report sections
// ---------------------------------------------------------------------------

Widget _buildMetricsWrap(List<SalesMetricCardData> metrics) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final availableWidth = constraints.maxWidth;
      const cardMinWidth = 220.0;
      final cols = (availableWidth / (cardMinWidth + AppSpacing.itemGap))
          .floor()
          .clamp(1, metrics.length);
      final cardWidth =
          (availableWidth - (cols - 1) * AppSpacing.itemGap) / cols;

      return Wrap(
        spacing: AppSpacing.itemGap,
        runSpacing: AppSpacing.itemGap,
        children: metrics
            .map(
              (metric) => SizedBox(
                width: cardWidth,
                child: _MetricCard(
                  title: metric.title,
                  value: metric.value,
                  subtitle: metric.subtitle,
                  icon: metric.icon,
                  color: metric.color,
                ),
              ),
            )
            .toList(),
      );
    },
  );
}

class _SalesReportSection extends StatelessWidget {
  const _SalesReportSection({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final summary = state.salesSummary ?? const <String, dynamic>{};
    final metrics = viewModel.getSalesMetricCards();
    final selectedSub = state.salesSubReport;
    final displayTo = state.salesTo.subtract(const Duration(days: 1));
    final totalAdjustments =
        (summary['discounts_total'] as num?)?.toDouble() ?? 0;
    final totalModifiers =
        (summary['modifier_sales_total'] as num?)?.toDouble() ?? 0;

    return ListView(
      padding: _sectionPadding,
      children: [
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(
            state.error!,
            style: const TextStyle(color: AppColors.destructive),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        // --- Sub-report selector ---
        Container(
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(_reportRadius),
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
                      color: AppColors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(_reportRadius),
                    ),
                    child: const Icon(
                      Icons.insights_outlined,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.itemGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Informe de ventas',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: AppColors.foreground,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Período ${DateFormat('dd MMM yyyy').format(state.salesFrom)} – ${DateFormat('dd MMM yyyy').format(displayTo)}',
                          style: const TextStyle(
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
                          borderRadius:
                              BorderRadius.circular(_reportRadius),
                          borderSide:
                              const BorderSide(color: AppColors.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(_reportRadius),
                          borderSide:
                              const BorderSide(color: AppColors.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(_reportRadius),
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
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
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
                    _CommercialStatTile(
                      label: 'Ventas netas',
                      value: currency.format(
                        (summary['net_sales'] as num?)?.toDouble() ?? 0,
                      ),
                      hint:
                          '${(summary['payments_count'] as num?)?.toInt() ?? 0} transacciones',
                    ),
                    _CommercialStatTile(
                      label: 'Ajustes aplicados',
                      value: currency.format(totalAdjustments),
                      hint:
                          '${(summary['discounted_lines_count'] as num?)?.toInt() ?? 0} líneas impactadas',
                    ),
                    _CommercialStatTile(
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
        // --- Metrics always visible ---
        _buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        // --- Conditional sub-report content ---
        ..._buildSubReportContent(
          context, selectedSub, currency,
        ),
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
          _ChartCard(
            title: 'Distribución de ventas por pago',
            rows: methodRows,
            color: AppColors.primary,
          ),
          const SizedBox(height: AppSpacing.sectionGap),
          LayoutBuilder(
            builder: (context, constraints) {
              final singleColumn =
                  constraints.maxWidth < AppBreakpoints.desktop;
              final cards = [
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
                ),
                _SalesCommercialReportCard(
                  title: 'Ventas por empleado',
                  subtitle:
                      'Rendimiento comercial por colaborador asignado.',
                  icon: Icons.person_outline,
                  color: const Color(0xFF7C3AED),
                  rows: viewModel.getEmployeeRows(),
                  emptyText: 'No hay ventas por empleado en el rango.',
                  amountLabel: 'Ventas',
                  countLabel: 'Órdenes',
                ),
                _SalesCommercialReportCard(
                  title: 'Ventas por tipo de pago',
                  subtitle:
                      'Composición de ingresos por método de cobro.',
                  icon: Icons.payments_outlined,
                  color: const Color(0xFF059669),
                  rows: viewModel.getPaymentMethodRows(),
                  emptyText: 'No hay pagos en el rango seleccionado.',
                  amountLabel: 'Cobrado',
                  countLabel: 'Pagos',
                ),
              ];
              if (singleColumn) {
                return Column(
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(height: AppSpacing.itemGap),
                      cards[i],
                    ],
                  ],
                );
              }
              final cardWidth =
                  (constraints.maxWidth - AppSpacing.itemGap * 2) / 3;
              return Wrap(
                spacing: AppSpacing.itemGap,
                runSpacing: AppSpacing.itemGap,
                children: cards
                    .map((c) => SizedBox(width: cardWidth, child: c))
                    .toList(growable: false),
              );
            },
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
          ),
        ];
      case SalesSubReport.byPayment:
        return [
          _ChartCard(
            title: 'Distribución de ventas por pago',
            rows: viewModel.getPaymentMethodRows(),
            color: AppColors.primary,
          ),
          const SizedBox(height: AppSpacing.itemGap),
          _SalesCommercialReportCard(
            title: 'Ventas por tipo de pago',
            subtitle: 'Composición de ingresos por método de cobro.',
            icon: Icons.payments_outlined,
            color: const Color(0xFF059669),
            rows: viewModel.getPaymentMethodRows(),
            emptyText: 'No hay pagos en el rango seleccionado.',
            amountLabel: 'Cobrado',
            countLabel: 'Pagos',
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
          ),
        ];
      case SalesSubReport.byDiscounts:
        return [
          _SalesCommercialReportCard(
            title: 'Descuentos y cortesías',
            subtitle:
                'Controla el impacto comercial de ajustes y concesiones.',
            icon: Icons.local_offer_outlined,
            color: const Color(0xFFDC2626),
            rows: viewModel.getDiscountRows(),
            emptyText: 'No hay descuentos ni cortesías aplicados.',
            showQuantity: true,
            amountLabel: 'Impacto',
            countLabel: 'Líneas',
          ),
        ];
      case SalesSubReport.byProduct:
        final productSalesRows = viewModel.getFilteredProductSalesRows();
        final productCategories =
            viewModel.getAvailableProductSalesCategories();
        final productTotals = productSalesRows.fold<Map<String, double>>(
          <String, double>{
            'quantity': 0,
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
          ),
        ];
      case SalesSubReport.byHour:
        return [
          _ChartCard(
            title: 'Ventas por hora',
            rows: viewModel.getHourlyRows(),
            color: const Color(0xFF7C3AED),
          ),
          const SizedBox(height: AppSpacing.itemGap),
          _SalesCommercialReportCard(
            title: 'Ventas por hora',
            subtitle: 'Actividad de ventas por franja horaria.',
            icon: Icons.schedule_outlined,
            color: const Color(0xFF7C3AED),
            rows: viewModel.getHourlyRows(),
            emptyText: 'No hay actividad en el rango.',
            amountLabel: 'Ventas',
            countLabel: 'Transacciones',
          ),
        ];
    }
  }
}

class _CommercialStatTile extends StatelessWidget {
  const _CommercialStatTile({
    required this.label,
    required this.value,
    required this.hint,
  });

  final String label;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(_reportRadius),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.mutedForeground,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            style: const TextStyle(
              color: AppColors.mutedForeground,
              fontSize: 12,
            ),
          ),
        ],
      ),
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
        borderRadius: BorderRadius.circular(_reportRadius),
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
                  borderRadius: BorderRadius.circular(_reportRadius),
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
                key: ValueKey('product-sales-query-${state.productSalesQuery}'),
                initialValue: state.productSalesQuery,
                onChanged: viewModel.setProductSalesQuery,
                decoration: InputDecoration(
                  hintText: 'Buscar producto o categoría',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(_reportRadius),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(_reportRadius),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(_reportRadius),
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
                    borderRadius: BorderRadius.circular(_reportRadius),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(_reportRadius),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(_reportRadius),
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
                  style: _reportOutlineButtonStyle(),
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
          ),
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.tightGap,
            runSpacing: AppSpacing.tightGap,
            children: [
              _CommercialStatTile(
                label: 'Productos visibles',
                value: '${rows.length}',
                hint: 'Filtrados sobre el rango activo',
              ),
              _CommercialStatTile(
                label: 'Unidades vendidas',
                value: (totals['quantity'] ?? 0).toStringAsFixed(2),
                hint: 'Cantidad consolidada',
              ),
              _CommercialStatTile(
                label: 'Ventas netas',
                value: currency.format(totals['netSales'] ?? 0),
                hint: 'Después de descuentos y cortesías',
              ),
              _CommercialStatTile(
                label: 'Ganancia bruta',
                value: currency.format(totals['grossProfit'] ?? 0),
                hint: 'Netas menos costo registrado',
              ),
            ]
                .map(
                  (tile) => SizedBox(width: 220, child: tile),
                )
                .toList(growable: false),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (rows.isEmpty)
            const _EmptyPlaceholder(
              icon: Icons.inventory_2_outlined,
              message:
                  'No hay productos que coincidan con los filtros del rango seleccionado.',
            )
          else
            _ProductSalesDataTable(rows: rows, totals: totals, currency: currency),
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
    label: Text(
      label,
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
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
              const DataColumn(
                numeric: true,
                label: Text('Cantidad'),
              ),
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
                        constraints: const BoxConstraints(minWidth: 180, maxWidth: 260),
                        child: Text(
                          row.product,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    DataCell(Text(row.category)),
                    DataCell(Text(row.quantitySold.toStringAsFixed(2))),
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
            borderRadius: BorderRadius.circular(_reportRadius),
            border: Border.all(color: AppColors.border),
          ),
          child: Wrap(
            spacing: AppSpacing.sectionGap,
            runSpacing: AppSpacing.itemGap,
            children: [
              _TotalPill(label: 'Cantidad', value: (totals['quantity'] ?? 0).toStringAsFixed(2)),
              _TotalPill(label: 'Brutas', value: currency.format(totals['grossSales'] ?? 0)),
              _TotalPill(label: 'Descuentos', value: currency.format(totals['discounts'] ?? 0)),
              _TotalPill(label: 'Cortesías', value: currency.format(totals['courtesies'] ?? 0)),
              _TotalPill(label: 'Netas', value: currency.format(totals['netSales'] ?? 0)),
              _TotalPill(label: 'Costo', value: currency.format(totals['cost'] ?? 0)),
              _TotalPill(label: 'Gan. bruta', value: currency.format(totals['grossProfit'] ?? 0)),
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

class _TotalPill extends StatelessWidget {
  const _TotalPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.mutedForeground,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.foreground,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

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

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final totalAmount = rows.fold<double>(0, (sum, row) => sum + row.amount);
    final totalCount = rows.fold<int>(0, (sum, row) => sum + row.count);
    final totalQuantity = rows.fold<double>(
      0,
      (sum, row) => sum + row.quantity,
    );
    final leader = rows.isEmpty ? 'Sin datos' : rows.first.label;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_reportRadius),
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
                  borderRadius: BorderRadius.circular(_reportRadius),
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
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: _CommercialStatTile(
                  label: amountLabel,
                  value: currency.format(totalAmount),
                  hint: 'Total acumulado',
                ),
              ),
              const SizedBox(width: AppSpacing.tightGap),
              Expanded(
                child: _CommercialStatTile(
                  label: countLabel,
                  value: '$totalCount',
                  hint: showQuantity
                      ? '${totalQuantity.toStringAsFixed(0)} unidades'
                      : 'Movimientos registrados',
                ),
              ),
              const SizedBox(width: AppSpacing.tightGap),
              Expanded(
                child: _CommercialStatTile(
                  label: 'Líder',
                  value: leader,
                  hint: rows.isEmpty ? 'Sin actividad' : 'Primer lugar',
                ),
              ),
            ],
          ),
          const Divider(height: AppSpacing.sectionGap),
          if (rows.isEmpty)
            _EmptyPlaceholder(icon: icon, message: emptyText)
          else
            _SalesCommercialTable(
              rows: rows.take(6).toList(growable: false),
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
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final totalAmount = rows.fold<double>(0, (sum, row) => sum + row.amount);
    final totalCount = rows.fold<int>(0, (sum, row) => sum + row.count);
    final totalQuantity = rows.fold<double>(
      0,
      (sum, row) => sum + row.quantity,
    );

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
            borderRadius: BorderRadius.circular(_reportRadius),
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: i.isEven ? Colors.white : AppColors.background,
              borderRadius: BorderRadius.circular(_reportRadius),
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
                    showQuantity ? rows[i].quantity.toStringAsFixed(0) : '—',
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
                    '${rows[i].count}',
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
            borderRadius: BorderRadius.circular(_reportRadius),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
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
                  '$totalCount',
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

class _FinanceReportSection extends StatelessWidget {
  const _FinanceReportSection({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final metrics = viewModel.getFinanceMetricCards();
    final typeRows = viewModel.getFinanceTypeRows();
    final sessionRows = viewModel.getFinanceSessionRows();
    final closures = viewModel.getCashClosureDetails();
    final balancedClosures = closures
        .where((row) => row['is_balanced'] == true)
        .length;
    final reviewedClosures = closures
        .where((row) => row['status']?.toString() == 'closed')
        .length;

    return ListView(
      padding: _sectionPadding,
      children: [
        _ReportHeroCard(
          title: 'Cierres de caja',
          subtitle:
              'Seguimiento operativo del cuadre, diferencias y movimientos manuales en un solo lugar.',
          accentColor: MangoColors.primaryOrange,
          trailing: [
            _HeroStat(label: 'Cierres revisados', value: '$reviewedClosures'),
            _HeroStat(label: 'Cuadrados', value: '$balancedClosures'),
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
        _buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        _ChartCard(
          title: 'Movimientos de caja',
          rows: typeRows,
          color: MangoColors.primaryOrange,
        ),
        const SizedBox(height: AppSpacing.itemGap),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn = constraints.maxWidth < AppBreakpoints.tablet;
            final cards = [
              _BreakdownCard(
                title: 'Movimientos por tipo',
                emptyText: 'No hay movimientos de caja en el rango.',
                emptyIcon: Icons.swap_vert_outlined,
                children: typeRows
                    .map(
                      (row) => _AmountRow(
                        label: row.label,
                        trailing:
                            '${currency.format(row.amount)} · ${row.count} movs',
                      ),
                    )
                    .toList(),
              ),
              _BreakdownCard(
                title: 'Estado de sesiones',
                emptyText: 'No hay sesiones de caja en el rango.',
                emptyIcon: Icons.lock_clock_outlined,
                children: sessionRows.map((row) {
                  final trailing = row.amount != 0
                      ? currency.format(row.amount)
                      : '${row.count} sesiones';
                  return _AmountRow(label: row.label, trailing: trailing);
                }).toList(),
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
        _SectionLabel(
          title: 'Detalle de cierre y cuadre',
          subtitle:
              'Comparación clara entre lo esperado por el sistema y lo reportado en el cierre.',
        ),
        const SizedBox(height: AppSpacing.itemGap),
        if (closures.isEmpty)
          const _SurfaceCard(
            child: _EmptyPlaceholder(
              icon: Icons.point_of_sale_outlined,
              message:
                  'No hay cierres de caja para mostrar en el rango seleccionado.',
            ),
          )
        else
          ...closures
              .take(12)
              .map(
                (closure) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.itemGap),
                  child: _CashClosureCard(closure: closure, currency: currency),
                ),
              ),
      ],
    );
  }
}

class _InventoryReportSection extends StatelessWidget {
  const _InventoryReportSection({required this.state, required this.viewModel});

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
      padding: _sectionPadding,
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
        _buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        _ChartCard(
          title: 'Movimientos de inventario',
          rows: movementRows,
          color: const Color(0xFF059669),
        ),
        const SizedBox(height: AppSpacing.itemGap),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn = constraints.maxWidth < AppBreakpoints.tablet;
            final cards = [
              _BreakdownCard(
                title: 'Top insumos por existencia',
                emptyText: 'No hay datos de stock para mostrar.',
                emptyIcon: Icons.inventory_outlined,
                children: topRows
                    .map(
                      (row) => _AmountRow(
                        label: row.label,
                        trailing: '${row.quantity.toStringAsFixed(2)} uds',
                      ),
                    )
                    .toList(),
              ),
              _BreakdownCard(
                title: 'Alertas de inventario',
                emptyText: 'No hay insumos en alerta ahora mismo.',
                emptyIcon: Icons.warning_amber_outlined,
                children: alertRows
                    .map(
                      (row) => _AmountRow(
                        label: row.label,
                        trailing: row.amount <= 0
                            ? 'Agotado'
                            : 'Stock ${row.amount.toStringAsFixed(2)} · mín ${row.quantity.toStringAsFixed(2)}',
                      ),
                    )
                    .toList(),
              ),
              _BreakdownCard(
                title: 'Movimientos recientes por tipo',
                emptyText: 'No hay movimientos recientes.',
                emptyIcon: Icons.swap_horiz_outlined,
                children: movementRows
                    .map(
                      (row) => _AmountRow(
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
            borderRadius: BorderRadius.circular(_reportRadius),
            border: Border.all(
              color: const Color(0xFF059669).withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.assessment_outlined, color: Color(0xFF059669)),
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

class _PurchasesReportSection extends StatelessWidget {
  const _PurchasesReportSection({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final metrics = viewModel.getPurchaseMetricCards();
    final statusRows = viewModel.getPurchaseStatusRows();
    final supplierRows = viewModel.getPurchaseSupplierRows();

    return ListView(
      padding: _sectionPadding,
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
        _buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        _ChartCard(
          title: 'Compras por estado',
          rows: statusRows,
          color: const Color(0xFF7C3AED),
        ),
        const SizedBox(height: AppSpacing.itemGap),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn = constraints.maxWidth < AppBreakpoints.tablet;
            final cards = [
              _BreakdownCard(
                title: 'Órdenes por estado',
                emptyText: 'No hay órdenes en el período.',
                emptyIcon: Icons.receipt_long_outlined,
                children: statusRows
                    .map(
                      (row) => _AmountRow(
                        label: row.label,
                        trailing:
                            '${currency.format(row.amount)} · ${row.count} órdenes',
                      ),
                    )
                    .toList(),
              ),
              _BreakdownCard(
                title: 'Top proveedores',
                emptyText: 'No hay proveedores con órdenes en el período.',
                emptyIcon: Icons.local_shipping_outlined,
                children: supplierRows
                    .map(
                      (row) => _AmountRow(
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

class _TaxReportSection extends StatelessWidget {
  const _TaxReportSection({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final metrics = viewModel.getTaxMetricCards();
    final taxRows = viewModel.getTaxTypeRows();
    final totalCharges = taxRows.fold<double>(
      0,
      (sum, row) => sum + row.amount,
    );

    return ListView(
      padding: _sectionPadding,
      children: [
        _ReportHeroCard(
          title: 'Impuestos',
          subtitle:
              'Vista fiscal limpia para revisar ITBIS, propina de ley y base gravable sin ruido visual.',
          accentColor: MangoColors.primaryOrange,
          trailing: [
            _HeroStat(
              label: 'Tipos con movimiento',
              value: '${taxRows.length}',
            ),
            _HeroStat(
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
        _buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        _ChartCard(
          title: 'Impuestos y ley por tipo',
          rows: taxRows,
          color: MangoColors.primaryOrange,
        ),
        const SizedBox(height: AppSpacing.itemGap),
        _SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionLabel(
                title: 'Detalle por tipo',
                subtitle:
                    'Cada fila muestra monto cobrado, base imponible y volumen de items.',
              ),
              const SizedBox(height: AppSpacing.lg),
              if (taxRows.isEmpty)
                const _EmptyPlaceholder(
                  icon: Icons.receipt_outlined,
                  message:
                      'No hay impuestos o propina de ley generados en el rango.',
                )
              else
                ...taxRows.map(
                  (row) => _LedgerRow(
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

class _FiscalReportSection extends StatelessWidget {
  const _FiscalReportSection({required this.state, required this.viewModel});

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

  static List<String> _collectTaxLabels(List<Map<String, dynamic>> documents) {
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
      padding: _sectionPadding,
      children: [
        _ReportHeroCard(
          title: 'Ventas por recibo / comprobante',
          subtitle:
              'Diseño listo para operar por rango de fecha y tipo de comprobante como filtros de primer nivel.',
          accentColor: MangoColors.primaryOrange,
          trailing: [
            _HeroStat(
              label: 'Documentos visibles',
              value: '${documents.length}',
            ),
            _HeroStat(
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
        _buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        _SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionLabel(
                title: 'Filtros del reporte',
                subtitle:
                    'El rango de fecha se controla desde la barra superior; aquí priorizamos el tipo de comprobante.',
              ),
              const SizedBox(height: AppSpacing.lg),
              Wrap(
                spacing: AppSpacing.tightGap,
                runSpacing: AppSpacing.tightGap,
                children: [
                  _DocumentTypeChip(
                    label: 'Todos',
                    selected: selectedType == null,
                    onTap: () => viewModel.setFiscalTypeFilter(null),
                  ),
                  ...availableTypes.map(
                    (type) => _DocumentTypeChip(
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
        _ChartCard(
          title: 'Comprobantes por tipo',
          rows: typeRows,
          color: MangoColors.primaryOrange,
        ),
        const SizedBox(height: AppSpacing.itemGap),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn = constraints.maxWidth < AppBreakpoints.tablet;
            final cards = [
              _BreakdownCard(
                title: 'Resumen por tipo de NCF',
                emptyText: 'No hay comprobantes fiscales emitidos en el rango.',
                emptyIcon: Icons.description_outlined,
                children: typeRows
                    .map(
                      (row) => _AmountRow(
                        label: row.label,
                        trailing:
                            '${currency.format(row.amount)} · ${row.count} docs',
                      ),
                    )
                    .toList(),
              ),
              _BreakdownCard(
                title: 'Desglose por impuesto',
                emptyText: 'No hay impuestos generados en los comprobantes.',
                emptyIcon: Icons.account_balance_outlined,
                children: taxBreakdownRows
                    .map(
                      (row) => _AmountRow(
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
        _SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionLabel(
                title: 'Detalle de comprobantes',
                subtitle:
                    'Tabla lista para auditoría diaria y exportación; respeta el filtro de tipo seleccionado.',
              ),
              const SizedBox(height: AppSpacing.lg),
              if (documents.isEmpty)
                const _EmptyPlaceholder(
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
                      const DataColumn(label: Text('Subtotal'), numeric: true),
                      ...taxLabels.map(
                        (label) =>
                            DataColumn(label: Text(label), numeric: true),
                      ),
                      const DataColumn(label: Text('Total'), numeric: true),
                      const DataColumn(label: Text('Estado')),
                      const DataColumn(label: Text('Fecha')),
                    ],
                    rows: documents.map((doc) {
                      final ncfNumber = doc['ncf_number']?.toString() ?? '';
                      final ncfType = doc['ncf_type']?.toString() ?? '';
                      final customerName =
                          doc['customer_name']?.toString() ??
                          'CONSUMIDOR FINAL';
                      final customerRnc =
                          doc['customer_rnc']?.toString() ?? '-';
                      final subtotal =
                          (doc['subtotal'] as num?)?.toDouble() ?? 0;
                      final total = (doc['total'] as num?)?.toDouble() ?? 0;
                      final status = doc['status']?.toString() ?? 'active';
                      final issuedAt =
                          DateTime.tryParse(
                            doc['issued_at']?.toString() ?? '',
                          ) ??
                          DateTime.now();
                      final isVoid = status != 'active';

                      return DataRow(
                        color: isVoid
                            ? WidgetStateProperty.all(
                                AppColors.destructive.withValues(alpha: 0.04),
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
                              constraints: const BoxConstraints(maxWidth: 180),
                              child: Text(
                                customerName,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(
                            Text(customerRnc.isEmpty ? '-' : customerRnc),
                          ),
                          DataCell(Text(currency.format(subtotal))),
                          ...taxLabels.map(
                            (label) => DataCell(
                              Text(
                                _taxAmountForLabel(doc, label) > 0
                                    ? currency.format(
                                        _taxAmountForLabel(doc, label),
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
                            _StatusTag(
                              label: isVoid ? 'Anulado' : 'Activo',
                              tone: isVoid
                                  ? AppColors.destructive
                                  : MangoColors.successGreen,
                            ),
                          ),
                          DataCell(Text(dateFormat.format(issuedAt.toLocal()))),
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

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_reportRadius),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: AppShadows.soft,
      ),
      child: child,
    );
  }
}

class _ReportHeroCard extends StatelessWidget {
  const _ReportHeroCard({
    required this.title,
    required this.subtitle,
    required this.accentColor,
    required this.trailing,
  });

  final String title;
  final String subtitle;
  final Color accentColor;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          final stats = Wrap(
            spacing: AppSpacing.itemGap,
            runSpacing: AppSpacing.itemGap,
            children: trailing,
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _heroCopy(),
                const SizedBox(height: AppSpacing.lg),
                stats,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _heroCopy()),
              const SizedBox(width: AppSpacing.sectionGap),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: stats,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _heroCopy() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(_reportRadius),
          ),
          child: Icon(Icons.analytics_outlined, color: accentColor),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          title,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 14,
            height: 1.4,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: MangoColors.bgLight,
        borderRadius: BorderRadius.circular(_reportRadius),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.mutedForeground,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 13,
            height: 1.35,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({
    required this.label,
    required this.primaryValue,
    required this.secondaryValue,
  });

  final String label;
  final String primaryValue;
  final String secondaryValue;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: MangoColors.cardBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.itemGap),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                primaryValue,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                secondaryValue,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(_reportRadius),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: tone,
        ),
      ),
    );
  }
}

class _DocumentTypeChip extends StatelessWidget {
  const _DocumentTypeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(_reportRadius),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? MangoColors.primaryOrange : Colors.white,
          borderRadius: BorderRadius.circular(_reportRadius),
          border: Border.all(
            color: selected
                ? MangoColors.primaryOrange
                : MangoColors.cardBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : AppColors.foreground,
          ),
        ),
      ),
    );
  }
}

class _CashClosureCard extends StatelessWidget {
  const _CashClosureCard({required this.closure, required this.currency});

  final Map<String, dynamic> closure;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final expectedTotal = (closure['expected_total'] as num?)?.toDouble() ?? 0;
    final reportedTotal = (closure['reported_total'] as num?)?.toDouble() ?? 0;
    final difference = (closure['difference'] as num?)?.toDouble() ?? 0;
    final openedAt = DateTime.tryParse(closure['opened_at']?.toString() ?? '');
    final closedAt = DateTime.tryParse(closure['closed_at']?.toString() ?? '');
    final diffColor = difference.abs() < 0.009
        ? MangoColors.successGreen
        : AppColors.destructive;

    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      closure['cashier_name']?.toString() ?? 'Cajero',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${closure['cash_register_name'] ?? 'Caja'} · ${openedAt != null ? DateFormat('dd/MM/yyyy HH:mm').format(AppTime.astFromInstant(openedAt)) : '-'}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                    if (closedAt != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Cierre: ${DateFormat('dd/MM/yyyy HH:mm').format(AppTime.astFromInstant(closedAt))}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.mutedForeground,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              _StatusTag(
                label: difference.abs() < 0.009 ? 'Cuadrado' : 'Con diferencia',
                tone: diffColor,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: _HeroStat(
                  label: 'Esperado',
                  value: currency.format(expectedTotal),
                ),
              ),
              const SizedBox(width: AppSpacing.itemGap),
              Expanded(
                child: _HeroStat(
                  label: 'Reportado',
                  value: currency.format(reportedTotal),
                ),
              ),
              const SizedBox(width: AppSpacing.itemGap),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.cardPadding),
                  decoration: BoxDecoration(
                    color: diffColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(_reportRadius),
                    border: Border.all(
                      color: diffColor.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Diferencia',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.mutedForeground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        currency.format(difference),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: diffColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          LayoutBuilder(
            builder: (context, constraints) {
              final vertical = constraints.maxWidth < 640;
              final items = [
                _LedgerRow(
                  label: 'Esperado efectivo',
                  primaryValue: currency.format(
                    (closure['expected_cash'] as num?)?.toDouble() ?? 0,
                  ),
                  secondaryValue: 'Sistema',
                ),
                _LedgerRow(
                  label: 'Reportado efectivo',
                  primaryValue: currency.format(
                    (closure['reported_cash'] as num?)?.toDouble() ?? 0,
                  ),
                  secondaryValue: 'Conteo final',
                ),
                _LedgerRow(
                  label: 'Tarjetas / transferencias',
                  primaryValue: currency.format(
                    ((closure['expected_card'] as num?)?.toDouble() ?? 0) +
                        ((closure['expected_transfer'] as num?)?.toDouble() ??
                            0),
                  ),
                  secondaryValue:
                      '${currency.format((closure['reported_card'] as num?)?.toDouble() ?? 0)} reportado en tarjetas · ${currency.format((closure['reported_transfer'] as num?)?.toDouble() ?? 0)} en transferencias',
                ),
              ];
              if (vertical) {
                return Column(children: items);
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (int i = 0; i < items.length; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.itemGap),
                    Expanded(child: items[i]),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RangeChip extends StatefulWidget {
  const _RangeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_RangeChip> createState() => _RangeChipState();
}

class _RangeChipState extends State<_RangeChip> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? MangoColors.primaryOrange
                : _isHovered
                ? MangoColors.primaryOrange.withValues(alpha: 0.08)
                : Colors.white,
            borderRadius: BorderRadius.circular(_reportRadius),
            border: Border.all(
              color: widget.selected
                  ? MangoColors.primaryOrange
                  : _isHovered
                  ? MangoColors.primaryOrange.withValues(alpha: 0.3)
                  : MangoColors.cardBorder,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: widget.selected ? Colors.white : AppColors.foreground,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.rows,
    required this.color,
  });

  final String title;
  final List<SalesBreakdownRow> rows;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final visibleRows = rows.take(8).toList(growable: false);
    final maxY = visibleRows.isEmpty
        ? 1.0
        : visibleRows
                  .map((e) => e.amount > 0 ? e.amount : e.count.toDouble())
                  .reduce((a, b) => a > b ? a : b) *
              1.2;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_reportRadius),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(Icons.bar_chart_rounded, size: 18, color: color),
              ),
              const SizedBox(width: AppSpacing.tightGap),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (visibleRows.isEmpty)
            const _EmptyPlaceholder(
              icon: Icons.bar_chart_outlined,
              message: 'No hay datos suficientes para graficar.',
            )
          else
            SizedBox(
              height: 240,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: maxY,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: AppColors.border,
                      strokeWidth: 1,
                      dashArray: [4, 4],
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        getTitlesWidget: (value, meta) => Text(
                          NumberFormat.compact().format(value),
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppColors.mutedForeground,
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= visibleRows.length) {
                            return const SizedBox.shrink();
                          }
                          final label = visibleRows[index].label;
                          final short = label.length > 10
                              ? '${label.substring(0, 10)}…'
                              : label;
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              short,
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: List.generate(visibleRows.length, (index) {
                    final row = visibleRows[index];
                    final y = row.amount > 0
                        ? row.amount
                        : row.count.toDouble();
                    return BarChartGroupData(
                      x: index,
                      barRods: [
                        BarChartRodData(
                          toY: y,
                          width: 24,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [color, color.withValues(alpha: 0.7)],
                          ),
                        ),
                      ],
                    );
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatefulWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;

  @override
  State<_MetricCard> createState() => _MetricCardState();
}

class _MetricCardState extends State<_MetricCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(_reportRadius),
          border: Border.all(
            color: _isHovered
                ? widget.color.withValues(alpha: 0.3)
                : AppColors.border,
          ),
          boxShadow: _isHovered ? AppShadows.cardInteractive : AppShadows.soft,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(_reportRadius),
              ),
              child: Icon(widget.icon, color: widget.color),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              widget.title,
              style: const TextStyle(
                color: AppColors.mutedForeground,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.value,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: AppColors.foreground,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.subtitle,
              style: const TextStyle(
                color: AppColors.mutedForeground,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({
    required this.title,
    required this.children,
    required this.emptyText,
    this.emptyIcon = Icons.info_outline,
  });

  final String title;
  final List<Widget> children;
  final String emptyText;
  final IconData emptyIcon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_reportRadius),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
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
          const Divider(height: AppSpacing.sectionGap),
          if (children.isEmpty)
            _EmptyPlaceholder(icon: emptyIcon, message: emptyText)
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: children.length,
              separatorBuilder: (_, index) => Divider(
                height: 1,
                color: AppColors.border.withValues(alpha: 0.5),
              ),
              itemBuilder: (_, index) => children[index],
            ),
        ],
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({required this.label, required this.trailing});

  final String label;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.tightGap),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: AppSpacing.tightGap),
          Flexible(
            child: Text(
              trailing,
              style: const TextStyle(
                color: AppColors.mutedForeground,
                fontSize: 13,
              ),
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPlaceholder extends StatelessWidget {
  const _EmptyPlaceholder({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sectionGap),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: AppColors.secondary.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: AppColors.mutedForeground),
            ),
            const SizedBox(height: AppSpacing.tightGap),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.mutedForeground,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportCard extends StatefulWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  const _ReportCard({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_ReportCard> createState() => _ReportCardState();
}

class _ReportCardState extends State<_ReportCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          transform: _isHovered
              ? (Matrix4.identity()..storage[13] = -4.0)
              : Matrix4.identity(),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(_reportRadius),
            border: Border.all(
              color: _isHovered
                  ? MangoColors.primaryOrange.withValues(alpha: 0.4)
                  : AppColors.border,
            ),
            boxShadow: _isHovered
                ? AppShadows.cardInteractive
                : AppShadows.soft,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: _isHovered
                      ? MangoColors.primaryOrange.withValues(alpha: 0.15)
                      : MangoColors.primaryOrange.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  widget.icon,
                  size: 40,
                  color: MangoColors.primaryOrange,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _isHovered
                        ? MangoColors.primaryOrange
                        : AppColors.foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportListItem extends StatefulWidget {
  final String title;
  final String description;
  final VoidCallback onTap;

  const _ReportListItem({
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  State<_ReportListItem> createState() => _ReportListItemState();
}

class _ReportListItemState extends State<_ReportListItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(_reportRadius),
            border: Border.all(
              color: _isHovered
                  ? MangoColors.primaryOrange.withValues(alpha: 0.3)
                  : AppColors.border,
            ),
            boxShadow: _isHovered
                ? AppShadows.cardInteractive
                : AppShadows.soft,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.foreground,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      widget.description,
                      style: const TextStyle(
                        color: AppColors.mutedForeground,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: _isHovered
                    ? MangoColors.primaryOrange
                    : AppColors.mutedForeground,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
