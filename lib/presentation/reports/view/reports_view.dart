import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_shadows.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

const double _reportRadius = 10.0;

/// Reports hub — shows a grid of report categories that link
/// to individual report screens via their own routes.
class ReportsView extends ConsumerStatefulWidget {
  const ReportsView({super.key, this.initialCategory});

  final ReportCategory? initialCategory;

  @override
  ConsumerState<ReportsView> createState() => _ReportsViewState();
}

class _ReportsViewState extends ConsumerState<ReportsView> {
  String? _lastBusinessId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // If we received an initial category via old ?tab= query param,
      // redirect to the new dedicated route immediately.
      if (widget.initialCategory != null) {
        _navigateToCategory(widget.initialCategory!);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ReportsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialCategory != widget.initialCategory &&
        widget.initialCategory != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _navigateToCategory(widget.initialCategory!);
      });
    }
  }

  void _navigateToCategory(ReportCategory category) {
    switch (category) {
      case ReportCategory.sales:
        context.go(AppRoutes.reportsSales);
      case ReportCategory.finances:
        context.go(AppRoutes.reportsFinances);
      case ReportCategory.inventory:
        context.go(AppRoutes.reportsInventory);
      case ReportCategory.purchases:
        context.go(AppRoutes.reportsPurchases);
      case ReportCategory.taxes:
        context.go(AppRoutes.reportsTaxes);
      case ReportCategory.fiscal:
        context.go(AppRoutes.reportsFiscal);
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
                              context.go(AppRoutes.dashboard);
                            }
                          },
                        ),
                      ),
                      const Expanded(
                        child: Text(
                          'Informes',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: AppColors.foreground,
                          ),
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
                  const SizedBox(height: AppSpacing.sm),
                  const Text(
                    'Mira y analiza todos los números que genera tu negocio',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _buildContent(context, state, viewModel),
            ),
          ],
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
                style: OutlinedButton.styleFrom(
                  foregroundColor: MangoColors.primaryOrange,
                  side: const BorderSide(color: MangoColors.primaryOrange),
                ),
                onPressed: viewModel.load,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    return _buildHubGrid(context, state, viewModel);
  }

  Widget _buildHubGrid(
    BuildContext context,
    ReportsState state,
    ReportsViewModel viewModel,
  ) {
    final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);

    // Build quick-stat summaries from loaded data
    final salesNet =
        (state.salesSummary?['net_sales'] as num?)?.toDouble() ?? 0;
    final salesCount =
        (state.salesSummary?['payments_count'] as num?)?.toInt() ?? 0;
    final cashNetFlow =
        (state.cashSummary?['net_cash_flow'] as num?)?.toDouble() ?? 0;
    final purchasesTotal =
        (state.purchasesSummary?['total_ordered'] as num?)?.toDouble() ?? 0;
    final inventoryItems =
        (state.inventorySummary?['total_items'] as num?)?.toInt() ?? 0;
    final taxTotal =
        (state.taxSummary?['total_tax_collected'] as num?)?.toDouble() ?? 0;
    final fiscalDocsCount =
        (state.fiscalSummary?['total_documents'] as num?)?.toInt() ?? 0;

    final cards = <_ReportHubCardData>[
      _ReportHubCardData(
        title: 'Ventas',
        description: 'Ingresos, métodos de pago, categorías, empleados y más.',
        icon: Icons.point_of_sale_rounded,
        color: const Color(0xFFF97316),
        quickStat: currency.format(salesNet),
        quickStatLabel: '$salesCount transacciones',
        onTap: () => context.go(AppRoutes.reportsSales),
      ),
      _ReportHubCardData(
        title: 'Cierres de caja',
        description: 'Cuadre, diferencias y movimientos manuales.',
        icon: Icons.point_of_sale_outlined,
        color: const Color(0xFF2563EB),
        quickStat: currency.format(cashNetFlow),
        quickStatLabel: 'Flujo neto de caja',
        onTap: () => context.go(AppRoutes.reportsFinances),
      ),
      _ReportHubCardData(
        title: 'Compras',
        description: 'Órdenes, recepción y proveedores del período.',
        icon: Icons.shopping_cart_outlined,
        color: const Color(0xFF7C3AED),
        quickStat: currency.format(purchasesTotal),
        quickStatLabel: 'Total ordenado',
        onTap: () => context.go(AppRoutes.reportsPurchases),
      ),
      _ReportHubCardData(
        title: 'Inventario',
        description: 'Existencias, alertas y movimientos recientes.',
        icon: Icons.inventory_2_outlined,
        color: const Color(0xFF059669),
        quickStat: '$inventoryItems',
        quickStatLabel: 'Items registrados',
        onTap: () => context.go(AppRoutes.reportsInventory),
      ),
      _ReportHubCardData(
        title: 'Impuestos',
        description: 'ITBIS, propina de ley y base gravable.',
        icon: Icons.receipt_long_outlined,
        color: const Color(0xFFDC2626),
        quickStat: currency.format(taxTotal),
        quickStatLabel: 'Total recaudado',
        onTap: () => context.go(AppRoutes.reportsTaxes),
      ),
      _ReportHubCardData(
        title: 'Comprobantes fiscales',
        description: 'NCF, desglose por tipo y detalle de documentos.',
        icon: Icons.description_outlined,
        color: const Color(0xFF0891B2),
        quickStat: '$fiscalDocsCount',
        quickStatLabel: 'Documentos emitidos',
        onTap: () => context.go(AppRoutes.reportsFiscal),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth >= AppBreakpoints.desktop
            ? 3
            : constraints.maxWidth >= AppBreakpoints.tablet
                ? 2
                : 1;

        return GridView.builder(
          padding: const EdgeInsets.all(AppSpacing.containerPadding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: AppSpacing.itemGap,
            crossAxisSpacing: AppSpacing.itemGap,
            childAspectRatio: crossAxisCount == 1 ? 2.8 : 1.8,
          ),
          itemCount: cards.length,
          itemBuilder: (context, index) {
            final card = cards[index];
            return _ReportHubCard(data: card);
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Hub card data model
// ---------------------------------------------------------------------------

class _ReportHubCardData {
  final String title;
  final String description;
  final IconData icon;
  final Color color;
  final String quickStat;
  final String quickStatLabel;
  final VoidCallback onTap;

  const _ReportHubCardData({
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
    required this.quickStat,
    required this.quickStatLabel,
    required this.onTap,
  });
}

// ---------------------------------------------------------------------------
// Hub card widget — shows icon, title, description, and a quick stat
// ---------------------------------------------------------------------------

class _ReportHubCard extends StatefulWidget {
  const _ReportHubCard({required this.data});

  final _ReportHubCardData data;

  @override
  State<_ReportHubCard> createState() => _ReportHubCardState();
}

class _ReportHubCardState extends State<_ReportHubCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.data;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: d.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(_reportRadius),
            border: Border.all(
              color: _isHovered
                  ? d.color.withValues(alpha: 0.4)
                  : AppColors.border,
            ),
            boxShadow: _isHovered ? AppShadows.cardInteractive : AppShadows.soft,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _isHovered
                          ? d.color.withValues(alpha: 0.15)
                          : d.color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(_reportRadius),
                    ),
                    child: Icon(d.icon, color: d.color, size: 28),
                  ),
                  const SizedBox(width: AppSpacing.itemGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.title,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: _isHovered
                                ? d.color
                                : AppColors.foreground,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          d.description,
                          style: const TextStyle(
                            color: AppColors.mutedForeground,
                            fontSize: 13,
                            height: 1.35,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _isHovered ? 0.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      color: _isHovered
                          ? d.color
                          : AppColors.mutedForeground,
                      size: 28,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: d.color.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(_reportRadius),
                  border: Border.all(
                    color: d.color.withValues(alpha: 0.12),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      d.quickStat,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: d.color,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.tightGap),
                    Expanded(
                      child: Text(
                        d.quickStatLabel,
                        style: const TextStyle(
                          color: AppColors.mutedForeground,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
