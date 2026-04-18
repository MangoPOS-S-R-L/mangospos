import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/presentation/reports/services/reports_csv_export_service.dart';
import 'package:mangopos/presentation/reports/services/reports_export_service.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// Shared scaffold for all individual report screens.
///
/// Provides: app bar with title, back navigation, refresh button,
/// date-range toolbar, PDF/CSV export buttons, and loading/error states.
class ReportScaffold extends ConsumerStatefulWidget {
  const ReportScaffold({
    super.key,
    required this.title,
    required this.category,
    required this.body,
  });

  final String title;
  final ReportCategory category;
  final Widget Function(ReportsState state, ReportsViewModel viewModel) body;

  @override
  ConsumerState<ReportScaffold> createState() => _ReportScaffoldState();
}

class _ReportScaffoldState extends ConsumerState<ReportScaffold> {
  String? _lastBusinessId;

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

    return Scaffold(
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
                          onPressed: () {
                            if (context.canPop()) {
                              context.pop();
                            } else {
                              context.go(AppRoutes.reports);
                            }
                          },
                        ),
                      ),
                      Expanded(
                        child: Text(
                          widget.title,
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
                          padding: const EdgeInsets.only(right: AppSpacing.sm),
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
                  const SizedBox(height: AppSpacing.itemGap),
                  _ReportToolbar(
                    state: state,
                    viewModel: viewModel,
                    category: widget.category,
                  ),
                ],
              ),
            ),
            Expanded(
              child: _buildBody(state, viewModel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ReportsState state, ReportsViewModel viewModel) {
    if (state.loading && state.salesSummary == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: MangoColors.primaryOrange),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              'Cargando informe...',
              style: TextStyle(color: AppColors.mutedForeground, fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (state.error != null) {
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
                style: reportOutlineButtonStyle(),
                onPressed: viewModel.load,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    return widget.body(state, viewModel);
  }
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

class _ReportToolbar extends StatelessWidget {
  const _ReportToolbar({
    required this.state,
    required this.viewModel,
    required this.category,
  });

  final ReportsState state;
  final ReportsViewModel viewModel;
  final ReportCategory category;

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd MMM yyyy');
    final displayedTo = state.salesTo.subtract(const Duration(days: 1));

    return Wrap(
      spacing: AppSpacing.tightGap,
      runSpacing: AppSpacing.tightGap,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ReportRangeChip(
          label: 'Hoy',
          selected: state.salesRangePreset == SalesReportRangePreset.today,
          onTap: () => viewModel.setSalesPreset(SalesReportRangePreset.today),
        ),
        ReportRangeChip(
          label: 'Ayer',
          selected: state.salesRangePreset == SalesReportRangePreset.yesterday,
          onTap: () =>
              viewModel.setSalesPreset(SalesReportRangePreset.yesterday),
        ),
        ReportRangeChip(
          label: 'Esta semana',
          selected: state.salesRangePreset == SalesReportRangePreset.thisWeek,
          onTap: () =>
              viewModel.setSalesPreset(SalesReportRangePreset.thisWeek),
        ),
        ReportRangeChip(
          label: 'Este mes',
          selected: state.salesRangePreset == SalesReportRangePreset.thisMonth,
          onTap: () =>
              viewModel.setSalesPreset(SalesReportRangePreset.thisMonth),
        ),
        OutlinedButton.icon(
          style: reportOutlineButtonStyle(),
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
        _ExportButton(
          icon: Icons.picture_as_pdf_outlined,
          label: 'PDF',
          color: const Color(0xFFDC2626),
          onPressed: () async {
            await ReportsExportService.exportCurrentReport(
              category: category,
              state: state,
              viewModel: viewModel,
            );
          },
        ),
        _ExportButton(
          icon: Icons.table_chart_outlined,
          label: 'Excel / CSV',
          color: const Color(0xFF059669),
          onPressed: () async {
            await ReportsCsvExportService.exportCurrentReport(
              category: category,
              state: state,
              viewModel: viewModel,
            );
          },
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.secondary,
            borderRadius: BorderRadius.circular(reportRadius),
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
// Export button
// ---------------------------------------------------------------------------

class _ExportButton extends StatelessWidget {
  const _ExportButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.4)),
        backgroundColor: color.withValues(alpha: 0.05),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(reportRadius),
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }
}
