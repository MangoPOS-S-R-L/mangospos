import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/app/widgets/date_range_modal.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/services/reports_csv_export_service.dart';
import 'package:mangopos/presentation/reports/services/reports_export_service.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/report_skeleton_view.dart';
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
  void initState() {
    super.initState();
    // Single point of entry-load. NO duplicar este loadCategory en build:
    // antes había una segunda llamada cuando _lastBusinessId era null
    // que disparaba un segundo load en paralelo y creaba race conditions
    // (tocar un chip durante ese intervalo dejaba data stale sobrescribir
    // la data fresca del chip nuevo).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastBusinessId =
          ref.read(sessionProvider).activeBusinessId; // sincroniza guard
      ref.read(reportsViewModelProvider.notifier)
          .loadCategory(widget.category);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final state = ref.watch(reportsViewModelProvider);
    final viewModel = ref.read(reportsViewModelProvider.notifier);

    // Solo recargamos si el business cambia DESPUÉS del initState
    // (ej: usuario cambia de negocio sin salir de la pantalla).
    if (session.activeBusinessId != null &&
        _lastBusinessId != null &&
        session.activeBusinessId != _lastBusinessId) {
      _lastBusinessId = session.activeBusinessId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        viewModel.loadCategory(widget.category);
      });
    }

    final isMobile = ResponsiveHelper.isMobile(context);
    final containerPad = isMobile ? 12.0 : AppSpacing.containerPadding;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.all(containerPad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Padding(
                        padding: EdgeInsets.only(
                          right: isMobile ? AppSpacing.sm : AppSpacing.lg,
                        ),
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
                          style: TextStyle(
                            fontSize: isMobile ? 18 : 28,
                            fontWeight: FontWeight.bold,
                            color: AppColors.foreground,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (state.loading && state.salesSummary == null)
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
                        onPressed: state.loading
                            ? null
                            : () => viewModel.loadCategory(widget.category),
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  SizedBox(height: isMobile ? 10 : AppSpacing.itemGap),
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

  /// True si NO hay snapshot cargado para la categoría de esta pantalla.
  /// Antes el check era global `salesSummary == null` — incorrecto para
  /// las otras 5 categorías porque mostraba el skeleton aunque el dato
  /// de esa categoría sí estuviera disponible.
  bool _hasNoDataForCategory(ReportsState state) {
    switch (widget.category) {
      case ReportCategory.sales:
        return state.salesSummary == null;
      case ReportCategory.offers:
        return state.offersSummary == null;
      case ReportCategory.finances:
        return state.cashSummary == null;
      case ReportCategory.purchases:
        return state.purchasesSummary == null;
      case ReportCategory.inventory:
        return state.inventorySummary == null;
      case ReportCategory.taxes:
        // El view de Impuestos pinta toda su data desde fiscalSummary
        // (NCFs emitidos). Solo eso decide si hay data — `taxSummary` es
        // legacy y ya no se carga en esta pantalla.
        return state.fiscalSummary == null;
      case ReportCategory.fiscal:
        return state.fiscalSummary == null;
    }
  }

  Widget _buildBody(ReportsState state, ReportsViewModel viewModel) {
    final noData = _hasNoDataForCategory(state);

    // Primera carga (sin snapshot todavía): skeleton con shimmer.
    if (state.loading && noData) {
      return const ReportSkeletonView();
    }

    if (state.error != null && noData) {
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
                onPressed: () => viewModel.loadCategory(widget.category),
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    // Refresh con data previa: stack que mantiene los datos visibles
    // con opacidad reducida + barra de progreso arriba, así el usuario
    // sabe que algo está pasando sin perder contexto.
    return Stack(
      children: [
        AnimatedOpacity(
          opacity: state.loading ? 0.55 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: IgnorePointer(
            ignoring: state.loading,
            child: widget.body(state, viewModel),
          ),
        ),
        if (state.loading)
          Positioned(
            top: 0, left: 0, right: 0,
            child: LinearProgressIndicator(
              minHeight: 3,
              backgroundColor: Colors.transparent,
              color: MangoColors.primaryOrange,
            ),
          ),
      ],
    );
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
          onPressed: () {
            showDialog<void>(
              context: context,
              builder: (ctx) => Dialog(
                backgroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                insetPadding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 40),
                child: SizedBox(
                  width: 400,
                  child: DateRangeModal(
                    initialFrom: state.salesFrom,
                    initialTo: state.salesTo,
                    onApply: (from, to) async {
                      await viewModel.setCustomSalesRange(from, to);
                    },
                    onClear: () {
                      viewModel
                          .setSalesPreset(SalesReportRangePreset.today);
                    },
                  ),
                ),
              ),
            );
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
