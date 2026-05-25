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
        // Hub: refresh secuencial de los 6 tiles. Limpia la categoría
        // seleccionada para que setSalesPreset desde el hub también
        // refresque todos los tiles (no solo la última categoría vista).
        viewModel.clearSelectedCategory();
        viewModel.loadHubSummary();
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
                              context.go(AppRoutes.dashboard);
                            }
                          },
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'Informes',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: isMobile ? 20 : 28,
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
                  SizedBox(height: AppSpacing.sm),
                  Text(
                    'Mira y analiza todos los números que genera tu negocio',
                    style: TextStyle(
                      fontSize: isMobile ? 13 : 16,
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
    final fiscalItbis =
        (state.fiscalSummary?['total_itbis'] as num?)?.toDouble() ?? 0;
    final fiscalServiceFee =
        (state.fiscalSummary?['total_service_fee'] as num?)?.toDouble() ?? 0;
    final taxTotal = fiscalItbis + fiscalServiceFee;
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
        title: 'Ventas por mesero',
        description:
            'Atribución de items y totales por empleado. Requiere modo '
            'multimesero activo.',
        icon: Icons.group_outlined,
        color: const Color(0xFF0EA5E9),
        quickStat: '—',
        quickStatLabel: 'Trazabilidad por línea',
        onTap: () => context.go(AppRoutes.reportsSalesByWaiter),
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
        disabled: true,
        disabledLabel: 'Próximamente',
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = ResponsiveHelper.isMobile(context);
        final crossAxisCount = constraints.maxWidth >= AppBreakpoints.desktop
            ? 3
            : constraints.maxWidth >= AppBreakpoints.tablet
                ? 2
                : 1;
        // En móvil la card 1-col luce muy estirada con aspect 2.8 — la
        // bajamos a 2.0 para que el contenido se vea balanceado.
        final aspect = crossAxisCount == 1
            ? (isMobile ? 2.0 : 2.8)
            : 1.8;

        return GridView.builder(
          padding: EdgeInsets.all(
            isMobile ? 12 : AppSpacing.containerPadding,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: isMobile ? 10 : AppSpacing.itemGap,
            crossAxisSpacing: isMobile ? 10 : AppSpacing.itemGap,
            childAspectRatio: aspect,
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
  final VoidCallback? onTap;
  final bool disabled;
  final String? disabledLabel;

  const _ReportHubCardData({
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
    required this.quickStat,
    required this.quickStatLabel,
    this.onTap,
    this.disabled = false,
    this.disabledLabel,
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
    final isDisabled = d.disabled;
    final effectiveColor = isDisabled ? AppColors.mutedForeground : d.color;
    final isMobile = ResponsiveHelper.isMobile(context);
    final cardPad = isMobile ? 14.0 : AppSpacing.cardPadding;

    return MouseRegion(
      onEnter: (_) {
        if (!isDisabled) setState(() => _isHovered = true);
      },
      onExit: (_) => setState(() => _isHovered = false),
      cursor: isDisabled
          ? SystemMouseCursors.forbidden
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: isDisabled ? null : d.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          padding: EdgeInsets.all(cardPad),
          decoration: BoxDecoration(
            color: isDisabled
                ? AppColors.secondary
                : Colors.white,
            borderRadius: BorderRadius.circular(_reportRadius),
            border: Border.all(
              color: _isHovered
                  ? effectiveColor.withValues(alpha: 0.4)
                  : AppColors.border,
            ),
            boxShadow:
                _isHovered ? AppShadows.cardInteractive : AppShadows.soft,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: EdgeInsets.all(isMobile ? 9 : 12),
                    decoration: BoxDecoration(
                      color: _isHovered
                          ? effectiveColor.withValues(alpha: 0.15)
                          : effectiveColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(_reportRadius),
                    ),
                    child: Icon(
                      d.icon,
                      color: effectiveColor,
                      size: isMobile ? 22 : 28,
                    ),
                  ),
                  SizedBox(
                    width: isMobile ? 10 : AppSpacing.itemGap,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                d.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: isMobile ? 15 : 18,
                                  fontWeight: FontWeight.w800,
                                  color: isDisabled
                                      ? AppColors.mutedForeground
                                      : (_isHovered
                                          ? d.color
                                          : AppColors.foreground),
                                ),
                              ),
                            ),
                            if (isDisabled && d.disabledLabel != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.mutedForeground
                                      .withValues(alpha: 0.12),
                                  borderRadius:
                                      BorderRadius.circular(6),
                                ),
                                child: Text(
                                  d.disabledLabel!,
                                  style: const TextStyle(
                                    color: AppColors.mutedForeground,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          d.description,
                          style: TextStyle(
                            color: AppColors.mutedForeground,
                            fontSize: isMobile ? 11.5 : 13,
                            height: 1.3,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (!isDisabled)
                    Icon(
                      Icons.chevron_right_rounded,
                      color: _isHovered
                          ? d.color
                          : AppColors.mutedForeground,
                      size: isMobile ? 22 : 28,
                    ),
                ],
              ),
              const Spacer(),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 10 : 14,
                  vertical: isMobile ? 8 : 10,
                ),
                decoration: BoxDecoration(
                  color: effectiveColor.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(_reportRadius),
                  border: Border.all(
                    color: effectiveColor.withValues(alpha: 0.12),
                  ),
                ),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        d.quickStat,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isMobile ? 15 : 20,
                          fontWeight: FontWeight.w800,
                          color: effectiveColor,
                        ),
                      ),
                    ),
                    SizedBox(width: AppSpacing.tightGap),
                    Expanded(
                      child: Text(
                        d.quickStatLabel,
                        style: TextStyle(
                          color: AppColors.mutedForeground,
                          fontSize: isMobile ? 11 : 12,
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
