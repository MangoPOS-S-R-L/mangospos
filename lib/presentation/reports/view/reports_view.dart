import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _appliedInitialCategory) return;
      if (widget.initialCategory != null) {
        ref
            .read(reportsViewModelProvider.notifier)
            .selectCategory(widget.initialCategory);
      }
      _appliedInitialCategory = true;
    });
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
      onPopInvoked: (didPop) {
        if (didPop) return;
        viewModel.selectCategory(null);
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (state.selectedCategory != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 16.0),
                            child: IconButton(
                              icon: const Icon(
                                Icons.arrow_back,
                                color: MangoColors.darkGray,
                              ),
                              onPressed: () => viewModel.selectCategory(null),
                            ),
                          ),
                        Text(
                          state.selectedCategory == null
                              ? 'Informes'
                              : viewModel.getCategoryTitle(
                                  state.selectedCategory!,
                                ),
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: MangoColors.darkGray,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Actualizar',
                          onPressed: state.loading ? null : viewModel.load,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    if (state.selectedCategory == null) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Mira y analiza todos los números que genera tu negocio',
                        style: TextStyle(
                          fontSize: 16,
                          color: MangoColors.muted,
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 16),
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
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null && state.selectedCategory == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Text(
            state.error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent),
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

    return state.selectedCategory == null
        ? _buildGrid(context, viewModel)
        : _buildReportList(context, viewModel, state.selectedCategory!);
  }

  Widget _buildGrid(BuildContext context, ReportsViewModel viewModel) {
    return GridView.count(
      crossAxisCount: 5,
      padding: const EdgeInsets.all(24),
      mainAxisSpacing: 24,
      crossAxisSpacing: 24,
      childAspectRatio: 1.0,
      children: ReportCategory.values.map((category) {
        return _ReportCard(
          title: viewModel.getCategoryTitle(category),
          icon: viewModel.getCategoryIcon(category),
          onTap: () => viewModel.selectCategory(category),
        );
      }).toList(),
    );
  }

  Widget _buildReportList(
    BuildContext context,
    ReportsViewModel viewModel,
    ReportCategory category,
  ) {
    final reports = viewModel.getReportsForCategory(category);

    return ListView.separated(
      padding: const EdgeInsets.all(24),
      itemCount: reports.length,
      separatorBuilder: (context, index) => const SizedBox(height: 16),
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
      spacing: 12,
      runSpacing: 12,
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
          onPressed: () async {
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2024, 1, 1),
              lastDate: DateTime.now().add(const Duration(days: 365)),
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
          onPressed: onExportPdf,
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: const Text('Exportar PDF'),
        ),
        OutlinedButton.icon(
          onPressed: onExportCsv,
          icon: const Icon(Icons.table_view_outlined),
          label: const Text('Exportar CSV'),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: MangoColors.sidebarBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: MangoColors.cardBorder),
          ),
          child: Text(
            '${dateFormat.format(state.salesFrom)} - ${dateFormat.format(displayedTo)}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _SalesReportSection extends StatelessWidget {
  const _SalesReportSection({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
    final metrics = viewModel.getSalesMetricCards();
    final methodRows = viewModel.getPaymentMethodRows();
    final hourlyRows = viewModel.getHourlyRows();
    final productRows = viewModel.getTopProductRows();

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        if (state.error != null) ...[
          const SizedBox(height: 16),
          Text(state.error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: metrics
              .map(
                (metric) => SizedBox(
                  width: 250,
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
        ),
        const SizedBox(height: 24),
        _ChartCard(
          title: 'Distribución de ventas',
          rows: methodRows,
          color: MangoColors.primaryOrange,
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn = constraints.maxWidth < 1100;
            if (singleColumn) {
              return Column(
                children: [
                  _BreakdownCard(
                    title: 'Ventas por método de pago',
                    emptyText: 'No hay pagos en el rango seleccionado.',
                    children: methodRows
                        .map(
                          (row) => _AmountRow(
                            label: row.label,
                            trailing:
                                '${currency.format(row.amount)} · ${row.count} tx',
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  _BreakdownCard(
                    title: 'Top productos vendidos',
                    emptyText: 'No hay productos cobrados en el rango.',
                    children: productRows
                        .map(
                          (row) => _AmountRow(
                            label: row.label,
                            trailing:
                                '${row.quantity.toStringAsFixed(0)} uds · ${currency.format(row.amount)}',
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  _BreakdownCard(
                    title: 'Ventas por hora',
                    emptyText: 'No hay actividad en el rango.',
                    children: hourlyRows
                        .map(
                          (row) => _AmountRow(
                            label: row.label,
                            trailing:
                                '${currency.format(row.amount)} · ${row.count} tx',
                          ),
                        )
                        .toList(),
                  ),
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _BreakdownCard(
                    title: 'Ventas por método de pago',
                    emptyText: 'No hay pagos en el rango seleccionado.',
                    children: methodRows
                        .map(
                          (row) => _AmountRow(
                            label: row.label,
                            trailing:
                                '${currency.format(row.amount)} · ${row.count} tx',
                          ),
                        )
                        .toList(),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _BreakdownCard(
                    title: 'Top productos vendidos',
                    emptyText: 'No hay productos cobrados en el rango.',
                    children: productRows
                        .map(
                          (row) => _AmountRow(
                            label: row.label,
                            trailing:
                                '${row.quantity.toStringAsFixed(0)} uds · ${currency.format(row.amount)}',
                          ),
                        )
                        .toList(),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _BreakdownCard(
                    title: 'Ventas por hora',
                    emptyText: 'No hay actividad en el rango.',
                    children: hourlyRows
                        .map(
                          (row) => _AmountRow(
                            label: row.label,
                            trailing:
                                '${currency.format(row.amount)} · ${row.count} tx',
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            );
          },
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

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        const Text(
          'Resumen consolidado de caja en el rango seleccionado.',
          style: TextStyle(color: MangoColors.muted, fontSize: 15),
        ),
        if (state.error != null) ...[
          const SizedBox(height: 16),
          Text(state.error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: metrics
              .map(
                (metric) => SizedBox(
                  width: 250,
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
        ),
        const SizedBox(height: 24),
        _ChartCard(
          title: 'Movimientos de caja',
          rows: typeRows,
          color: const Color(0xFF2563EB),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn = constraints.maxWidth < 900;
            if (singleColumn) {
              return Column(
                children: [
                  _BreakdownCard(
                    title: 'Movimientos por tipo',
                    emptyText: 'No hay movimientos de caja en el rango.',
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
                  const SizedBox(height: 16),
                  _BreakdownCard(
                    title: 'Estado de sesiones',
                    emptyText: 'No hay sesiones de caja en el rango.',
                    children: sessionRows.map((row) {
                      final trailing = row.amount != 0
                          ? currency.format(row.amount)
                          : '${row.count} sesiones';
                      return _AmountRow(label: row.label, trailing: trailing);
                    }).toList(),
                  ),
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _BreakdownCard(
                    title: 'Movimientos por tipo',
                    emptyText: 'No hay movimientos de caja en el rango.',
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
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _BreakdownCard(
                    title: 'Estado de sesiones',
                    emptyText: 'No hay sesiones de caja en el rango.',
                    children: sessionRows.map((row) {
                      final trailing = row.amount != 0
                          ? currency.format(row.amount)
                          : '${row.count} sesiones';
                      return _AmountRow(label: row.label, trailing: trailing);
                    }).toList(),
                  ),
                ),
              ],
            );
          },
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
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        const Text(
          'Visión general de existencias, alertas y movimientos recientes.',
          style: TextStyle(color: MangoColors.muted, fontSize: 15),
        ),
        if (state.error != null) ...[
          const SizedBox(height: 16),
          Text(state.error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: metrics
              .map(
                (metric) => SizedBox(
                  width: 250,
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
        ),
        const SizedBox(height: 24),
        _ChartCard(
          title: 'Movimientos de inventario',
          rows: movementRows,
          color: const Color(0xFF059669),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn = constraints.maxWidth < 1100;
            if (singleColumn) {
              return Column(
                children: [
                  _BreakdownCard(
                    title: 'Top insumos por existencia',
                    emptyText: 'No hay datos de stock para mostrar.',
                    children: topRows
                        .map(
                          (row) => _AmountRow(
                            label: row.label,
                            trailing: '${row.quantity.toStringAsFixed(2)} uds',
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  _BreakdownCard(
                    title: 'Alertas de inventario',
                    emptyText: 'No hay insumos en alerta ahora mismo.',
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
                  const SizedBox(height: 16),
                  _BreakdownCard(
                    title: 'Movimientos recientes por tipo',
                    emptyText: 'No hay movimientos recientes.',
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
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _BreakdownCard(
                    title: 'Top insumos por existencia',
                    emptyText: 'No hay datos de stock para mostrar.',
                    children: topRows
                        .map(
                          (row) => _AmountRow(
                            label: row.label,
                            trailing: '${row.quantity.toStringAsFixed(2)} uds',
                          ),
                        )
                        .toList(),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _BreakdownCard(
                    title: 'Alertas de inventario',
                    emptyText: 'No hay insumos en alerta ahora mismo.',
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
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _BreakdownCard(
                    title: 'Movimientos recientes por tipo',
                    emptyText: 'No hay movimientos recientes.',
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
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Text(
          'Valor de inventario estimado: ${currency.format((state.inventorySummary?['total_stock_value'] as num?)?.toDouble() ?? 0)}',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: MangoColors.darkGray,
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
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        const Text(
          'Resumen de órdenes, recepción y proveedores del período.',
          style: TextStyle(color: MangoColors.muted, fontSize: 15),
        ),
        if (state.error != null) ...[
          const SizedBox(height: 16),
          Text(state.error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: metrics
              .map(
                (metric) => SizedBox(
                  width: 250,
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
        ),
        const SizedBox(height: 24),
        _ChartCard(
          title: 'Compras por estado',
          rows: statusRows,
          color: const Color(0xFF7C3AED),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn = constraints.maxWidth < 900;
            if (singleColumn) {
              return Column(
                children: [
                  _BreakdownCard(
                    title: 'Órdenes por estado',
                    emptyText: 'No hay órdenes en el período.',
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
                  const SizedBox(height: 16),
                  _BreakdownCard(
                    title: 'Top proveedores',
                    emptyText: 'No hay proveedores con órdenes en el período.',
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
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _BreakdownCard(
                    title: 'Órdenes por estado',
                    emptyText: 'No hay órdenes en el período.',
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
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _BreakdownCard(
                    title: 'Top proveedores',
                    emptyText: 'No hay proveedores con órdenes en el período.',
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
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _RangeChip extends StatelessWidget {
  const _RangeChip({
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
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? MangoColors.primaryOrange : Colors.white,
          borderRadius: BorderRadius.circular(999),
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
            color: selected ? Colors.white : MangoColors.darkGray,
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
    final visibleRows = rows.take(6).toList(growable: false);
    final maxY = visibleRows.isEmpty
        ? 1.0
        : visibleRows
                  .map((e) => e.amount > 0 ? e.amount : e.count.toDouble())
                  .reduce((a, b) => a > b ? a : b) *
              1.2;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 14),
          if (visibleRows.isEmpty)
            const Text(
              'No hay datos suficientes para graficar.',
              style: TextStyle(color: MangoColors.muted),
            )
          else
            SizedBox(
              height: 220,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: maxY,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: MangoColors.cardBorder,
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
                        reservedSize: 36,
                        getTitlesWidget: (value, meta) => Text(
                          NumberFormat.compact().format(value),
                          style: const TextStyle(
                            fontSize: 10,
                            color: MangoColors.muted,
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
                                color: MangoColors.muted,
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
                          borderRadius: BorderRadius.circular(6),
                          color: color,
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

class _MetricCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(
              color: MangoColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: MangoColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({
    required this.title,
    required this.children,
    required this.emptyText,
  });

  final String title;
  final List<Widget> children;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 14),
          if (children.isEmpty)
            Text(emptyText, style: const TextStyle(color: MangoColors.muted))
          else
            ...children,
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
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          Text(trailing, style: const TextStyle(color: MangoColors.muted)),
        ],
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  const _ReportCard({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: MangoColors.cardBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: MangoColors.primaryOrange.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: MangoColors.primaryOrange),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: MangoColors.darkGray,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportListItem extends StatelessWidget {
  final String title;
  final String description;
  final VoidCallback onTap;

  const _ReportListItem({
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: MangoColors.cardBorder),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(
                      color: MangoColors.muted,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: MangoColors.muted),
          ],
        ),
      ),
    );
  }
}
