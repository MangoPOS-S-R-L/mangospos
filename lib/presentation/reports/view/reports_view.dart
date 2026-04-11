import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
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
                          padding:
                              const EdgeInsets.only(right: AppSpacing.lg),
                          child: IconButton(
                            icon: const Icon(
                              Icons.arrow_back,
                              color: AppColors.foreground,
                            ),
                            onPressed: () =>
                                _handleBack(state, viewModel),
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
                                right: AppSpacing.sm),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: 'Actualizar',
                          onPressed:
                              state.loading ? null : viewModel.load,
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
                          await ReportsCsvExportService
                              .exportCurrentReport(
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
            CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              'Cargando informes...',
              style: TextStyle(
                color: AppColors.mutedForeground,
                fontSize: 14,
              ),
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
        final crossAxisCount =
            constraints.maxWidth >= AppBreakpoints.desktop
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
          selected:
              state.salesRangePreset == SalesReportRangePreset.today,
          onTap: () =>
              viewModel.setSalesPreset(SalesReportRangePreset.today),
        ),
        _RangeChip(
          label: 'Ayer',
          selected:
              state.salesRangePreset == SalesReportRangePreset.yesterday,
          onTap: () => viewModel
              .setSalesPreset(SalesReportRangePreset.yesterday),
        ),
        _RangeChip(
          label: 'Esta semana',
          selected:
              state.salesRangePreset == SalesReportRangePreset.thisWeek,
          onTap: () => viewModel
              .setSalesPreset(SalesReportRangePreset.thisWeek),
        ),
        _RangeChip(
          label: 'Este mes',
          selected:
              state.salesRangePreset == SalesReportRangePreset.thisMonth,
          onTap: () => viewModel
              .setSalesPreset(SalesReportRangePreset.thisMonth),
        ),
        OutlinedButton.icon(
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
            await viewModel.setCustomSalesRange(
                picked.start, picked.end);
          },
          icon: const Icon(Icons.date_range_outlined),
          label: const Text('Rango personalizado'),
        ),
        OutlinedButton.icon(
          onPressed: onExportPdf,
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: const Text('PDF'),
        ),
        OutlinedButton.icon(
          onPressed: onExportCsv,
          icon: const Icon(Icons.table_view_outlined),
          label: const Text('CSV'),
        ),
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.secondary,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.calendar_today,
                  size: 14, color: AppColors.mutedForeground),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${dateFormat.format(state.salesFrom)} – ${dateFormat.format(displayedTo)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13),
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
      final cols =
          (availableWidth / (cardMinWidth + AppSpacing.itemGap))
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

const _sectionPadding = EdgeInsets.fromLTRB(
    AppSpacing.containerPadding,
    0,
    AppSpacing.containerPadding,
    AppSpacing.containerPadding);

class _SalesReportSection extends StatelessWidget {
  const _SalesReportSection(
      {required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  static IconData _filterIcon(SalesBreakdownFilter filter) {
    switch (filter) {
      case SalesBreakdownFilter.paymentMethod:
        return Icons.payment_outlined;
      case SalesBreakdownFilter.product:
        return Icons.inventory_2_outlined;
      case SalesBreakdownFilter.category:
        return Icons.category_outlined;
      case SalesBreakdownFilter.employee:
        return Icons.person_outlined;
      case SalesBreakdownFilter.zone:
        return Icons.place_outlined;
      case SalesBreakdownFilter.hourly:
        return Icons.schedule_outlined;
    }
  }

  ({String title, String emptyText, IconData emptyIcon, List<SalesBreakdownRow> rows})
      _breakdownData(SalesBreakdownFilter filter) {
    switch (filter) {
      case SalesBreakdownFilter.paymentMethod:
        return (
          title: 'Ventas por método de pago',
          emptyText: 'No hay pagos en el rango seleccionado.',
          emptyIcon: Icons.payment_outlined,
          rows: viewModel.getPaymentMethodRows(),
        );
      case SalesBreakdownFilter.product:
        return (
          title: 'Top productos vendidos',
          emptyText: 'No hay productos cobrados en el rango.',
          emptyIcon: Icons.inventory_2_outlined,
          rows: viewModel.getTopProductRows(),
        );
      case SalesBreakdownFilter.category:
        return (
          title: 'Ventas por categoría',
          emptyText: 'No hay ventas por categoría en el rango.',
          emptyIcon: Icons.category_outlined,
          rows: viewModel.getCategoryRows(),
        );
      case SalesBreakdownFilter.employee:
        return (
          title: 'Ventas por empleado',
          emptyText: 'No hay ventas por empleado en el rango.',
          emptyIcon: Icons.person_outlined,
          rows: viewModel.getEmployeeRows(),
        );
      case SalesBreakdownFilter.zone:
        return (
          title: 'Ventas por zona',
          emptyText: 'No hay ventas por zona en el rango.',
          emptyIcon: Icons.place_outlined,
          rows: viewModel.getZoneRows(),
        );
      case SalesBreakdownFilter.hourly:
        return (
          title: 'Ventas por hora',
          emptyText: 'No hay actividad en el rango.',
          emptyIcon: Icons.schedule_outlined,
          rows: viewModel.getHourlyRows(),
        );
    }
  }

  bool _showQuantity(SalesBreakdownFilter filter) =>
      filter == SalesBreakdownFilter.product ||
      filter == SalesBreakdownFilter.category;

  @override
  Widget build(BuildContext context) {
    final currency =
        NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final metrics = viewModel.getSalesMetricCards();
    final methodRows = viewModel.getPaymentMethodRows();
    final selectedFilter = state.salesBreakdownFilter;
    final data = _breakdownData(selectedFilter);
    final maxAmount = data.rows.isEmpty
        ? 1.0
        : data.rows
            .map((r) => r.amount)
            .reduce((a, b) => a > b ? a : b);

    return ListView(
      padding: _sectionPadding,
      children: [
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(state.error!,
              style: const TextStyle(color: AppColors.destructive)),
        ],
        const SizedBox(height: AppSpacing.xl),
        _buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        _ChartCard(
          title: 'Distribución de ventas',
          rows: methodRows,
          color: AppColors.primary,
        ),
        const SizedBox(height: AppSpacing.sectionGap),
        // --- Breakdown filter selector ---
        Container(
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.soft,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      borderRadius:
                          BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Icon(
                      _filterIcon(selectedFilter),
                      size: 18,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.tightGap),
                  Expanded(
                    child: Text(
                      data.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              // Filter chips
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: SalesBreakdownFilter.values.map((filter) {
                    final selected = filter == selectedFilter;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius:
                              BorderRadius.circular(20),
                          onTap: () => viewModel
                              .setSalesBreakdownFilter(filter),
                          child: AnimatedContainer(
                            duration:
                                const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? AppColors.primary
                                  : AppColors.secondary,
                              borderRadius:
                                  BorderRadius.circular(20),
                              border: Border.all(
                                color: selected
                                    ? AppColors.primary
                                    : AppColors.border,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _filterIcon(filter),
                                  size: 15,
                                  color: selected
                                      ? Colors.white
                                      : AppColors.mutedForeground,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  viewModel
                                      .breakdownFilterLabel(filter),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: selected
                                        ? Colors.white
                                        : AppColors.foreground,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const Divider(height: AppSpacing.sectionGap),
              // Rows
              if (data.rows.isEmpty)
                _EmptyPlaceholder(
                  icon: data.emptyIcon,
                  message: data.emptyText,
                )
              else
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: data.rows.length,
                  itemBuilder: (_, index) {
                    final row = data.rows[index];
                    final fraction =
                        maxAmount > 0 ? row.amount / maxAmount : 0.0;
                    final showQty = _showQuantity(selectedFilter);
                    return Padding(
                      padding: const EdgeInsets.only(
                          bottom: AppSpacing.sm),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              // Rank badge
                              Container(
                                width: 26,
                                height: 26,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: index < 3
                                      ? AppColors.primary
                                          .withValues(alpha: 0.1)
                                      : AppColors.secondary,
                                  borderRadius:
                                      BorderRadius.circular(
                                          AppRadius.sm),
                                ),
                                child: Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: index < 3
                                        ? AppColors.primary
                                        : AppColors.mutedForeground,
                                  ),
                                ),
                              ),
                              const SizedBox(
                                  width: AppSpacing.tightGap),
                              Expanded(
                                child: Text(
                                  row.label,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(
                                  width: AppSpacing.sm),
                              Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    currency.format(row.amount),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                      color: AppColors.foreground,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    showQty
                                        ? '${row.quantity.toStringAsFixed(0)} uds · ${row.count} ventas'
                                        : '${row.count} transacciones',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color:
                                          AppColors.mutedForeground,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          // Progress bar
                          ClipRRect(
                            borderRadius:
                                BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: fraction,
                              minHeight: 4,
                              backgroundColor:
                                  AppColors.secondary,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(
                                index == 0
                                    ? AppColors.primary
                                    : AppColors.primary
                                        .withValues(
                                            alpha:
                                                0.4 +
                                                    0.6 * fraction),
                              ),
                            ),
                          ),
                          if (index < data.rows.length - 1)
                            const SizedBox(
                                height: AppSpacing.sm),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FinanceReportSection extends StatelessWidget {
  const _FinanceReportSection(
      {required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency =
        NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final metrics = viewModel.getFinanceMetricCards();
    final typeRows = viewModel.getFinanceTypeRows();
    final sessionRows = viewModel.getFinanceSessionRows();

    return ListView(
      padding: _sectionPadding,
      children: [
        const Text(
          'Resumen consolidado de caja en el rango seleccionado.',
          style:
              TextStyle(color: AppColors.mutedForeground, fontSize: 15),
        ),
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(state.error!,
              style: const TextStyle(color: AppColors.destructive)),
        ],
        const SizedBox(height: AppSpacing.xl),
        _buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        _ChartCard(
          title: 'Movimientos de caja',
          rows: typeRows,
          color: const Color(0xFF2563EB),
        ),
        const SizedBox(height: AppSpacing.itemGap),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn =
                constraints.maxWidth < AppBreakpoints.tablet;
            final cards = [
              _BreakdownCard(
                title: 'Movimientos por tipo',
                emptyText: 'No hay movimientos de caja en el rango.',
                emptyIcon: Icons.swap_vert_outlined,
                children: typeRows
                    .map((row) => _AmountRow(
                          label: row.label,
                          trailing:
                              '${currency.format(row.amount)} · ${row.count} movs',
                        ))
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
                  return _AmountRow(
                      label: row.label, trailing: trailing);
                }).toList(),
              ),
            ];

            if (singleColumn) {
              return Column(
                children: [
                  for (int i = 0; i < cards.length; i++) ...[
                    if (i > 0)
                      const SizedBox(height: AppSpacing.itemGap),
                    cards[i],
                  ],
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < cards.length; i++) ...[
                  if (i > 0)
                    const SizedBox(width: AppSpacing.itemGap),
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

class _InventoryReportSection extends StatelessWidget {
  const _InventoryReportSection(
      {required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency =
        NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final metrics = viewModel.getInventoryMetricCards();
    final topRows = viewModel.getInventoryTopStockRows();
    final alertRows = viewModel.getInventoryAlertRows();
    final movementRows = viewModel.getInventoryMovementRows();

    return ListView(
      padding: _sectionPadding,
      children: [
        const Text(
          'Visión general de existencias, alertas y movimientos recientes.',
          style:
              TextStyle(color: AppColors.mutedForeground, fontSize: 15),
        ),
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(state.error!,
              style: const TextStyle(color: AppColors.destructive)),
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
            final singleColumn =
                constraints.maxWidth < AppBreakpoints.tablet;
            final cards = [
              _BreakdownCard(
                title: 'Top insumos por existencia',
                emptyText: 'No hay datos de stock para mostrar.',
                emptyIcon: Icons.inventory_outlined,
                children: topRows
                    .map((row) => _AmountRow(
                          label: row.label,
                          trailing:
                              '${row.quantity.toStringAsFixed(2)} uds',
                        ))
                    .toList(),
              ),
              _BreakdownCard(
                title: 'Alertas de inventario',
                emptyText: 'No hay insumos en alerta ahora mismo.',
                emptyIcon: Icons.warning_amber_outlined,
                children: alertRows
                    .map((row) => _AmountRow(
                          label: row.label,
                          trailing: row.amount <= 0
                              ? 'Agotado'
                              : 'Stock ${row.amount.toStringAsFixed(2)} · mín ${row.quantity.toStringAsFixed(2)}',
                        ))
                    .toList(),
              ),
              _BreakdownCard(
                title: 'Movimientos recientes por tipo',
                emptyText: 'No hay movimientos recientes.',
                emptyIcon: Icons.swap_horiz_outlined,
                children: movementRows
                    .map((row) => _AmountRow(
                          label: row.label,
                          trailing:
                              '${row.amount.toStringAsFixed(2)} uds · ${row.count} movs',
                        ))
                    .toList(),
              ),
            ];

            if (singleColumn) {
              return Column(
                children: [
                  for (int i = 0; i < cards.length; i++) ...[
                    if (i > 0)
                      const SizedBox(height: AppSpacing.itemGap),
                    cards[i],
                  ],
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < cards.length; i++) ...[
                  if (i > 0)
                    const SizedBox(width: AppSpacing.itemGap),
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
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
                color:
                    const Color(0xFF059669).withValues(alpha: 0.15)),
          ),
          child: Row(
            children: [
              const Icon(Icons.assessment_outlined,
                  color: Color(0xFF059669)),
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
  const _PurchasesReportSection(
      {required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency =
        NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final metrics = viewModel.getPurchaseMetricCards();
    final statusRows = viewModel.getPurchaseStatusRows();
    final supplierRows = viewModel.getPurchaseSupplierRows();

    return ListView(
      padding: _sectionPadding,
      children: [
        const Text(
          'Resumen de órdenes, recepción y proveedores del período.',
          style:
              TextStyle(color: AppColors.mutedForeground, fontSize: 15),
        ),
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(state.error!,
              style: const TextStyle(color: AppColors.destructive)),
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
            final singleColumn =
                constraints.maxWidth < AppBreakpoints.tablet;
            final cards = [
              _BreakdownCard(
                title: 'Órdenes por estado',
                emptyText: 'No hay órdenes en el período.',
                emptyIcon: Icons.receipt_long_outlined,
                children: statusRows
                    .map((row) => _AmountRow(
                          label: row.label,
                          trailing:
                              '${currency.format(row.amount)} · ${row.count} órdenes',
                        ))
                    .toList(),
              ),
              _BreakdownCard(
                title: 'Top proveedores',
                emptyText:
                    'No hay proveedores con órdenes en el período.',
                emptyIcon: Icons.local_shipping_outlined,
                children: supplierRows
                    .map((row) => _AmountRow(
                          label: row.label,
                          trailing:
                              '${currency.format(row.amount)} · ${row.count} órdenes',
                        ))
                    .toList(),
              ),
            ];

            if (singleColumn) {
              return Column(
                children: [
                  for (int i = 0; i < cards.length; i++) ...[
                    if (i > 0)
                      const SizedBox(height: AppSpacing.itemGap),
                    cards[i],
                  ],
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < cards.length; i++) ...[
                  if (i > 0)
                    const SizedBox(width: AppSpacing.itemGap),
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
  const _TaxReportSection(
      {required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency =
        NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final metrics = viewModel.getTaxMetricCards();
    final taxRows = viewModel.getTaxTypeRows();

    return ListView(
      padding: _sectionPadding,
      children: [
        const Text(
          'Resumen de impuestos y propina de ley cobrados por tipo en el rango seleccionado.',
          style:
              TextStyle(color: AppColors.mutedForeground, fontSize: 15),
        ),
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(state.error!,
              style: const TextStyle(color: AppColors.destructive)),
        ],
        const SizedBox(height: AppSpacing.xl),
        _buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        _ChartCard(
          title: 'Impuestos y ley por tipo',
          rows: taxRows,
          color: const Color(0xFFB45309),
        ),
        const SizedBox(height: AppSpacing.itemGap),
        _BreakdownCard(
          title: 'Detalle por tipo de impuesto o ley',
          emptyText:
              'No hay impuestos o propina de ley generados en el rango.',
          emptyIcon: Icons.receipt_outlined,
          children: taxRows
              .map((row) => _AmountRow(
                    label: row.label,
                    trailing:
                        '${currency.format(row.amount)} · Base ${currency.format(row.quantity)} · ${row.count} items',
                  ))
              .toList(),
        ),
      ],
    );
  }
}

class _FiscalReportSection extends StatelessWidget {
  const _FiscalReportSection(
      {required this.state, required this.viewModel});

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

  @override
  Widget build(BuildContext context) {
    final currency =
        NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final dateFormat = DateFormat('dd/MM/yyyy hh:mm a');
    final metrics = viewModel.getFiscalMetricCards();
    final typeRows = viewModel.getFiscalTypeRows();
    final documents = viewModel.getFiscalDocuments();

    return ListView(
      padding: _sectionPadding,
      children: [
        const Text(
          'Ventas con comprobante fiscal (NCF) en el rango seleccionado. Exporta a PDF para tu reporte DGII.',
          style:
              TextStyle(color: AppColors.mutedForeground, fontSize: 15),
        ),
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(state.error!,
              style: const TextStyle(color: AppColors.destructive)),
        ],
        const SizedBox(height: AppSpacing.xl),
        _buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        _ChartCard(
          title: 'Comprobantes por tipo',
          rows: typeRows,
          color: const Color(0xFF2563EB),
        ),
        const SizedBox(height: AppSpacing.itemGap),
        _BreakdownCard(
          title: 'Resumen por tipo de NCF',
          emptyText:
              'No hay comprobantes fiscales emitidos en el rango.',
          emptyIcon: Icons.description_outlined,
          children: typeRows
              .map((row) => _AmountRow(
                    label: row.label,
                    trailing:
                        '${currency.format(row.amount)} · ${row.count} docs',
                  ))
              .toList(),
        ),
        const SizedBox(height: AppSpacing.sectionGap),
        // --- Documents table ---
        Container(
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.card),
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
                      color: const Color(0xFF2563EB)
                          .withValues(alpha: 0.1),
                      borderRadius:
                          BorderRadius.circular(AppRadius.sm),
                    ),
                    child: const Icon(
                      Icons.table_chart_outlined,
                      size: 18,
                      color: Color(0xFF2563EB),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.tightGap),
                  const Expanded(
                    child: Text(
                      'Detalle de comprobantes fiscales',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                      ),
                    ),
                  ),
                  Text(
                    '${documents.length} registros',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ],
              ),
              const Divider(height: AppSpacing.sectionGap),
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
                      AppColors.secondary,
                    ),
                    dataRowMinHeight: 40,
                    dataRowMaxHeight: 56,
                    columnSpacing: 20,
                    horizontalMargin: 12,
                    columns: const [
                      DataColumn(
                          label: Text('NCF',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12))),
                      DataColumn(
                          label: Text('Tipo',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12))),
                      DataColumn(
                          label: Text('Cliente',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12))),
                      DataColumn(
                          label: Text('RNC/Cédula',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12))),
                      DataColumn(
                          label: Text('Subtotal',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12)),
                          numeric: true),
                      DataColumn(
                          label: Text('ITBIS',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12)),
                          numeric: true),
                      DataColumn(
                          label: Text('Total',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12)),
                          numeric: true),
                      DataColumn(
                          label: Text('Estado',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12))),
                      DataColumn(
                          label: Text('Fecha',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12))),
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
                      final itbis =
                          (doc['itbis_amount'] as num?)?.toDouble() ??
                              0;
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
                                    .withValues(alpha: 0.05))
                            : null,
                        cells: [
                          DataCell(Text(
                            ncfNumber,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                              color: isVoid
                                  ? AppColors.mutedForeground
                                  : AppColors.foreground,
                            ),
                          )),
                          DataCell(Text(
                            _ncfTypeName(ncfType),
                            style: const TextStyle(fontSize: 12),
                          )),
                          DataCell(
                            ConstrainedBox(
                              constraints: const BoxConstraints(
                                  maxWidth: 160),
                              child: Text(
                                customerName,
                                style:
                                    const TextStyle(fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(Text(
                            customerRnc.isEmpty ? '-' : customerRnc,
                            style: const TextStyle(fontSize: 12),
                          )),
                          DataCell(Text(
                            currency.format(subtotal),
                            style: const TextStyle(fontSize: 12),
                          )),
                          DataCell(Text(
                            currency.format(itbis),
                            style: const TextStyle(fontSize: 12),
                          )),
                          DataCell(Text(
                            currency.format(total),
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color: isVoid
                                  ? AppColors.mutedForeground
                                  : AppColors.foreground,
                            ),
                          )),
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isVoid
                                    ? AppColors.destructive
                                        .withValues(alpha: 0.1)
                                    : const Color(0xFF059669)
                                        .withValues(alpha: 0.1),
                                borderRadius:
                                    BorderRadius.circular(12),
                              ),
                              child: Text(
                                isVoid ? 'Anulado' : 'Activo',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: isVoid
                                      ? AppColors.destructive
                                      : const Color(0xFF059669),
                                ),
                              ),
                            ),
                          ),
                          DataCell(Text(
                            dateFormat.format(issuedAt.toLocal()),
                            style: const TextStyle(fontSize: 12),
                          )),
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
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? AppColors.primary
                : _isHovered
                    ? AppColors.primary.withValues(alpha: 0.08)
                    : AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(
              color: widget.selected
                  ? AppColors.primary
                  : _isHovered
                      ? AppColors.primary.withValues(alpha: 0.3)
                      : AppColors.border,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: widget.selected
                  ? Colors.white
                  : AppColors.foreground,
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
                .map(
                    (e) => e.amount > 0 ? e.amount : e.count.toDouble())
                .reduce((a, b) => a > b ? a : b) *
            1.2;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
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
                child: Icon(Icons.bar_chart_rounded,
                    size: 18, color: color),
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
                          if (index < 0 ||
                              index >= visibleRows.length) {
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
                  barGroups:
                      List.generate(visibleRows.length, (index) {
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
                          borderRadius:
                              BorderRadius.circular(AppRadius.sm),
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              color,
                              color.withValues(alpha: 0.7),
                            ],
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
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(
            color: _isHovered
                ? widget.color.withValues(alpha: 0.3)
                : AppColors.border,
          ),
          boxShadow:
              _isHovered ? AppShadows.cardInteractive : AppShadows.soft,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.card),
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
                  color: AppColors.mutedForeground, fontSize: 12),
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
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
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
            _EmptyPlaceholder(
              icon: emptyIcon,
              message: emptyText,
            )
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
      padding:
          const EdgeInsets.symmetric(vertical: AppSpacing.tightGap),
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
                  color: AppColors.mutedForeground, fontSize: 13),
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
  const _EmptyPlaceholder({
    required this.icon,
    required this.message,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(vertical: AppSpacing.sectionGap),
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
              child: Icon(
                icon,
                size: 32,
                color: AppColors.mutedForeground,
              ),
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
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              color: _isHovered
                  ? AppColors.primary.withValues(alpha: 0.4)
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
                      ? AppColors.primary.withValues(alpha: 0.15)
                      : AppColors.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child:
                    Icon(widget.icon, size: 40, color: AppColors.primary),
              ),
              const SizedBox(height: AppSpacing.lg),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm),
                child: Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _isHovered
                        ? AppColors.primary
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
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              color: _isHovered
                  ? AppColors.primary.withValues(alpha: 0.3)
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
                    ? AppColors.primary
                    : AppColors.mutedForeground,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
