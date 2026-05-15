import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_shadows.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'widgets/hoverable_card.dart';

class DashboardView extends ConsumerStatefulWidget {
  const DashboardView({super.key});

  @override
  ConsumerState<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends ConsumerState<DashboardView> {
  String? _lastBusinessId;

  bool _redirected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _guardDashboardAccess();
      ref.read(cashierViewModelProvider).init();
    });
  }

  void _guardDashboardAccess() {
    if (_redirected) return;
    final ctrl = ref.read(sessionProvider.notifier);
    if (!ctrl.canAccessDashboard) {
      _redirected = true;
      context.go(ctrl.homeRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(cashierViewModelProvider);
    final session = ref.watch(sessionProvider);

    // Redirect non-admin/supervisor users to their home screen
    if (session.isAuthenticated && !_redirected) {
      final ctrl = ref.read(sessionProvider.notifier);
      if (!ctrl.canAccessDashboard) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_redirected) {
            _redirected = true;
            context.go(ctrl.homeRoute);
          }
        });
        return const SizedBox.shrink();
      }
    }

    if (session.activeBusinessId != null &&
        session.activeBusinessId != _lastBusinessId) {
      _lastBusinessId = session.activeBusinessId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(cashierViewModelProvider).init();
      });
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;

          // Responsive Breakpoints (design system)
          final isMobile = width < AppBreakpoints.mobile;
          final isDesktopXL = width >= AppBreakpoints.desktop;

          // Split View: Desktop XL and above (>=1280dp)
          final isSplitView = width >= AppBreakpoints.desktop;

          // Spacing Strategy (design system)
          final padding = const EdgeInsets.all(AppSpacing.containerPadding);
          final double gap = AppSpacing.sectionGap;

          return SingleChildScrollView(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // WELCOME CARD
                _WelcomeCard(
                  isVertical: isMobile,
                  viewModel: vm,
                  session: session,
                ),
                SizedBox(height: gap),

                // MAIN LAYOUT
                if (isSplitView)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // LEFT COLUMN (Main Content)
                      Expanded(
                        flex: 2,
                        child: Column(
                          children: [
                            _QuickActionsSection(width: width),
                            SizedBox(height: gap),
                            _SalesChart(viewModel: vm, isMobile: isMobile),
                          ],
                        ),
                      ),
                      SizedBox(width: gap),
                      // RIGHT COLUMN (Sidebar: Active Tables)
                      Expanded(
                        flex: 1,
                        child: _ActiveTablesWidget(
                          viewModel: vm,
                          isWide: isDesktopXL,
                        ),
                      ),
                    ],
                  )
                else
                  // STACKED LAYOUT (Mobile & Tablet)
                  Column(
                    children: [
                      _QuickActionsSection(width: width),
                      SizedBox(height: gap),
                      _SalesChart(viewModel: vm, isMobile: isMobile),
                      SizedBox(height: gap),
                      _ActiveTablesWidget(viewModel: vm, isWide: isDesktopXL),
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ============================================================================
// 1. WELCOME CARD
// ============================================================================

class _WelcomeCard extends StatelessWidget {
  final bool isVertical;
  final CashierViewModel viewModel;
  final SessionState session;

  const _WelcomeCard({
    this.isVertical = false,
    required this.viewModel,
    required this.session,
  });

  @override
  Widget build(BuildContext context) {
    // Padding responsive: mobile 16px, tablet/desktop 24px
    final cardPadding = isVertical ? 16.0 : 24.0;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(cardPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border, width: 1),
        boxShadow: AppShadows.cardElevated,
      ),
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final businessName = viewModel.businessName.trim().isEmpty
        ? 'Negocio no configurado'
        : viewModel.businessName;
    final userName = session.userName?.trim().isNotEmpty == true
        ? session.userName!.trim()
        : 'Usuario';
    final registerName = viewModel.currentRegisterName.trim().isNotEmpty
        ? viewModel.currentRegisterName.trim()
        : 'Caja sin configurar';
    final isCashOpen = viewModel.isCashOpen;
    final statusColor = isCashOpen ? AppColors.success : AppColors.warning;
    final statusLabel = isCashOpen ? 'Caja abierta' : 'Caja cerrada';
    final actionLabel = isCashOpen ? 'Gestionar Caja' : 'Aperturar Caja';
    final actionIcon = isCashOpen ? Icons.point_of_sale : Icons.lock_open;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Date - uppercase per spec
        Text(
          DateFormat(
            'EEEE, d de MMMM yyyy',
            'es',
          ).format(AppTime.nowAst()).toUpperCase(),
          style: const TextStyle(
            color: AppColors.mutedForeground,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),

        // Welcome & Meta.
        // En vertical (móvil) el Flex vive dentro de un SingleChildScrollView,
        // por lo que un hijo flexed con altura no acotada rompe el layout.
        // Usamos Flexible(loose) en vertical (hijo toma su tamaño intrínseco)
        // y Expanded en horizontal (hijo ocupa el ancho restante).
        Flex(
          direction: isVertical ? Axis.vertical : Axis.horizontal,
          mainAxisSize: isVertical ? MainAxisSize.min : MainAxisSize.max,
          crossAxisAlignment: isVertical
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            Flexible(
              fit: isVertical ? FlexFit.loose : FlexFit.tight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  RichText(
                    text: TextSpan(
                      style: TextStyle(
                        // Título más pequeño en mobile para mejor proporción
                        fontSize: isVertical ? 24 : 30,
                        fontWeight: FontWeight.bold,
                        height: 1.2,
                        fontFamily: 'Plus Jakarta Sans',
                      ),
                      children: [
                        const TextSpan(
                          text: '¡Bienvenido a ',
                          style: TextStyle(color: AppColors.foreground),
                        ),
                        TextSpan(
                          text: 'MangoPOS',
                          style: TextStyle(color: AppColors.primary),
                        ),
                        const TextSpan(
                          text: '!',
                          style: TextStyle(color: AppColors.foreground),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: isVertical ? 8 : 12,
                  ), // Menos espacio en mobile
                  // Meta Info
                  Wrap(
                    spacing: AppSpacing.sectionGap,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _metaItem(const Color(0xFF22C55E), businessName),
                      _metaDot(),
                      _metaText('Usuario: $userName'),
                      _metaDot(),
                      _metaIconText(Icons.attach_money, registerName),
                    ],
                  ),
                ],
              ),
            ),

            // Gap - reducido en mobile
            SizedBox(height: isVertical ? 16 : 0, width: isVertical ? 0 : 24),

            // Right Zone: Actions - full width en mobile
            if (isVertical)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Badge "Caja cerrada"
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(AppRadius.button),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isCashOpen
                              ? Icons.check_circle_outline
                              : Icons.watch_later_outlined,
                          size: 16,
                          color: statusColor,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          statusLabel,
                          style: TextStyle(
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Button "Aperturar Caja" - Full width
                  Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          AppColors.primary,
                          AppColors.primaryGradientEnd,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.button),
                      boxShadow: AppShadows.soft,
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => context.go(AppRoutes.cashier),
                        borderRadius: BorderRadius.circular(AppRadius.button),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(actionIcon, color: Colors.white, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                actionLabel,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            else
              // Desktop: Row layout
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Badge "Caja cerrada"
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(AppRadius.button),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isCashOpen
                              ? Icons.check_circle_outline
                              : Icons.watch_later_outlined,
                          size: 16,
                          color: statusColor,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          statusLabel,
                          style: TextStyle(
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Button "Aperturar Caja"
                  Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          AppColors.primary,
                          AppColors.primaryGradientEnd,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.button),
                      boxShadow: AppShadows.soft,
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => context.go(AppRoutes.cashier),
                        borderRadius: BorderRadius.circular(AppRadius.button),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Icon(actionIcon, color: Colors.white, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                actionLabel,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }

  Widget _metaItem(Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            color: AppColors.mutedForeground,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _metaText(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.mutedForeground,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _metaIconText(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: AppColors.mutedForeground),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(
            color: AppColors.mutedForeground,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _metaDot() {
    return Container(
      width: 4,
      height: 4,
      decoration: BoxDecoration(
        color: AppColors.border,
        shape: BoxShape.circle,
      ),
    );
  }
}

// ============================================================================
// 2. QUICK ACTIONS
// ============================================================================

class _QuickActionsSection extends StatelessWidget {
  final double width;

  const _QuickActionsSection({required this.width});

  @override
  Widget build(BuildContext context) {
    // Quick Actions Grid Columns:
    // <1024px: 2 columns
    // >=1024px: 4 columns
    final gridColumns = width < AppBreakpoints.tablet ? 2 : 4;

    // Aspect ratio responsive with better visual balance
    final aspectRatio = width < 640
        ? 1.15
        : (width < 1024 ? 1.3 : (width < 1280 ? 1.35 : 1.4));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Acciones Rápidas',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(height: AppSpacing.itemGap),
        GridView.builder(
          itemCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: gridColumns,
            mainAxisSpacing: AppSpacing.sectionGap,
            crossAxisSpacing: AppSpacing.sectionGap,
            childAspectRatio: aspectRatio,
            mainAxisExtent: 122,
          ),
          itemBuilder: (context, index) {
            final items = [
              (
                Icons.people_outline,
                'Mozos',
                'Ventas y mesas por mesero',
                AppColors.info,
                '/ajustes/mozos',
              ),
              (
                Icons.print_outlined,
                'Imprimir Productos',
                'Etiquetas y códigos',
                AppColors.success,
                '/productos',
              ),
              (
                Icons.receipt_long,
                'Comprobantes',
                'NCF y facturas',
                AppColors.warning,
                '/reportes',
              ),
              (
                Icons.campaign_outlined,
                'Publicidad',
                'Promociones activas',
                AppColors.primary,
                '/ajustes/publicidad',
              ),
            ];
            final item = items[index];
            return _actionCard(
              context,
              item.$1,
              item.$2,
              item.$3,
              item.$4,
              item.$5,
            );
          },
        ),
        const SizedBox(height: AppSpacing.sectionGap),
        // Large Buttons Layout - en móvil (<600) stack vertical; en tablet/
        // desktop dos columnas.
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked = constraints.maxWidth < AppBreakpoints.mobile;
            final itemWidth = stacked
                ? constraints.maxWidth
                : (constraints.maxWidth - AppSpacing.sectionGap) / 2;
            return Wrap(
              spacing: AppSpacing.sectionGap,
              runSpacing: AppSpacing.sectionGap,
              children: [
                SizedBox(width: itemWidth, child: _largeButton(context, true)),
                SizedBox(width: itemWidth, child: _largeButton(context, false)),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _actionCard(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    Color color,
    String route,
  ) {
    // Spec 3.2.1: Small Action Card
    // - Icon: 48x48px container with 24px icon
    // - Padding: 16px
    // - Left-aligned content
    // - Min height: 110px (SPEC REQUIREMENT)
    return HoverableCard(
      onTap: () => context.go(route),
      borderColor: color.withValues(
        alpha: 0.4,
      ), // Different color for each card
      child: Container(
        padding: const EdgeInsets.all(14),
        constraints: const BoxConstraints.tightFor(height: 122),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            // Icon Container - 48x48px per spec
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppRadius.md), // 8px
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(height: 8),
            // Title - semibold per spec
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w600, // semibold
                fontSize: 14,
                color: AppColors.foreground,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            // Subtitle
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.mutedForeground,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _largeButton(BuildContext context, bool isPrimary) {
    // Spec 3.2.2: Nueva Venta (gradient)
    // Spec 3.2.3: Delivery (white card with badge)
    final route = isPrimary ? AppRoutes.sales : null;
    final subtitle = isPrimary ? 'Iniciar orden' : 'No disponible';
    final iconBackground = isPrimary
        ? Colors.white.withValues(alpha: 0.2)
        : AppColors.info.withValues(alpha: 0.1);
    final subtitleColor = isPrimary
        ? Colors.white.withValues(alpha: 0.8)
        : AppColors.mutedForeground;
    final trailingIconColor = Colors.white.withValues(alpha: 0.7);
    final badgeColor = Colors.grey.withValues(alpha: 0.15);
    final badgeBorderColor = Colors.grey.withValues(alpha: 0.25);

    return HoverableCard(
      onTap: route == null ? null : () => context.go(route),
      child: Container(
        height: 80, // Fixed 80px per spec
        decoration: BoxDecoration(
          color: isPrimary ? null : Colors.white,
          gradient: isPrimary
              ? const LinearGradient(
                  colors: [AppColors.primary, AppColors.primaryGradientEnd],
                )
              : null,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: isPrimary ? null : Border.all(color: AppColors.border),
          boxShadow: AppShadows.soft,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              // Icon Container - 56x56px per spec
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: iconBackground,
                  borderRadius: BorderRadius.circular(AppRadius.card), // 12px
                ),
                child: Icon(
                  isPrimary ? Icons.add : Icons.delivery_dining,
                  color: isPrimary ? Colors.white : AppColors.info,
                  size: 28, // 7x7 (28px)
                ),
              ),
              const SizedBox(width: 12),
              // Text content
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title - 18px semibold per spec
                    Text(
                      isPrimary ? 'Nueva Venta' : 'Delivery',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600, // semibold
                        fontSize: 18, // text-lg per spec
                        height: 1,
                        color: isPrimary ? Colors.white : AppColors.foreground,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Subtitle - 14px per spec
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14, // text-sm per spec
                        color: subtitleColor,
                      ),
                    ),
                  ],
                ),
              ),
              // Right side element
              if (isPrimary)
                // Arrow icon for Nueva Venta
                Icon(Icons.arrow_forward, size: 20, color: trailingIconColor)
              else
                // Badge for Delivery (spec: "4 en ruta")
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    border: Border.all(color: badgeBorderColor),
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                  child: Text(
                    'No disponible',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade700,
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

//

// ============================================================================
// 3. SALES CHART
// ============================================================================

class _SalesChart extends StatelessWidget {
  final CashierViewModel viewModel;
  final bool isMobile;

  const _SalesChart({required this.viewModel, required this.isMobile});

  @override
  Widget build(BuildContext context) {
    // 1. Prepare Data
    final currency = NumberFormat('#,##0', 'en_US');
    final sales = viewModel.weeklySales; // List<double> of length 7
    final totalSales = viewModel.totalWeeklySales;
    final weeklyAverage = viewModel.weeklyAverage;
    final bestDay = viewModel.bestDayAmount;

    // 2. Create Spots
    final spots = List.generate(sales.length, (index) {
      return FlSpot(index.toDouble(), sales[index]);
    });

    // 3. Dynamic Y-Axis
    double maxSale = 0;
    for (final s in sales) {
      if (s > maxSale) maxSale = s;
    }
    final maxY = maxSale > 0 ? maxSale * 1.2 : 10000.0;
    final interval = maxY / 4;

    final padding = const EdgeInsets.all(AppSpacing.cardPadding);
    final chartHeight = 256.0;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border, width: 1),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Resumen de Ventas',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.foreground,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Últimos 7 días',
                    style: TextStyle(
                      color: AppColors.mutedForeground,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: const [
                    Icon(
                      Icons.calendar_today,
                      size: 14,
                      color: AppColors.mutedForeground,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Esta semana',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sectionGap),

          // Metrics Grid
          // Mobile/Tablet (<1024px): 2 columns (wrapped)
          // Desktop (≥1024px): 3-4 columns in a row
          // Wide (≥1440px): Can show more
          _buildMetricsGrid(currency, totalSales, weeklyAverage, bestDay),
          const SizedBox(height: AppSpacing.sectionGap),

          // Chart
          SizedBox(
            height: chartHeight,
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: interval,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: AppColors.border.withValues(alpha: 0.5),
                    strokeWidth: 1,
                    dashArray: [4, 4],
                  ),
                ),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: interval,
                      reservedSize: 40,
                      getTitlesWidget: (value, meta) {
                        if (value == 0) return const SizedBox();
                        return Text(
                          NumberFormat.compact().format(value),
                          style: const TextStyle(
                            color: AppColors.mutedForeground,
                            fontSize: 10,
                          ),
                        );
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: false, // Keep concise
                    ),
                  ),
                  rightTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    color: AppColors.primary,
                    barWidth: 3,
                    isStrokeCapRound: true,
                    dotData: FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: AppColors.primary.withValues(alpha: 0.1),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: AppColors.success,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'Datos actualizados en tiempo real',
                style: TextStyle(
                  color: AppColors.mutedForeground,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsGrid(
    NumberFormat currency,
    double totalSales,
    double weeklyAverage,
    double bestDay,
  ) {
    final metrics = [
      {
        'label': 'Total Ventas',
        'value': 'RD\$${currency.format(totalSales)}',
        'color': AppColors.success,
      },
      {
        'label': 'Promedio Diario',
        'value': 'RD\$${currency.format(weeklyAverage)}',
        'color': AppColors.info,
      },
      {
        'label': 'Día Récord',
        'value': 'RD\$${currency.format(bestDay)}',
        'color': AppColors.primary,
      },
    ];

    // Responsive layout:
    // Mobile/Tablet: Wrap with 2 columns
    // Desktop+: Row with equal expansion
    if (isMobile) {
      // Use Wrap for 2-column layout on mobile/tablet
      return LayoutBuilder(
        builder: (context, constraints) {
          final itemWidth = (constraints.maxWidth - AppSpacing.sectionGap) / 2;
          return Wrap(
            spacing: AppSpacing.sectionGap,
            runSpacing: AppSpacing.sectionGap,
            children: metrics.map((m) {
              return SizedBox(
                width: itemWidth,
                child: _metricBox(
                  m['label'] as String,
                  m['value'] as String,
                  m['color'] as Color,
                ),
              );
            }).toList(),
          );
        },
      );
    } else {
      // Desktop: Row layout with equal expansion
      return Row(
        children: [
          for (int i = 0; i < metrics.length; i++) ...[
            Expanded(
              child: _metricBox(
                metrics[i]['label'] as String,
                metrics[i]['value'] as String,
                metrics[i]['color'] as Color,
              ),
            ),
            if (i < metrics.length - 1) const SizedBox(width: 16),
          ],
        ],
      );
    }
  }

  Widget _metricBox(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.mutedForeground,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 4. ACTIVE TABLES WIDGET
// ============================================================================

class _ActiveTablesWidget extends StatelessWidget {
  final CashierViewModel viewModel;
  final bool isWide;
  const _ActiveTablesWidget({required this.viewModel, this.isWide = false});

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _resolveTableCode(TableSession session, int index) {
    final code = session.tableName;
    if (code != null && code.trim().isNotEmpty) {
      return code.trim();
    }

    if (session.origin == 'dine_in') {
      return 'SP${(index + 1).toString().padLeft(2, '0')}';
    }
    if (session.origin == 'takeout') {
      return 'TO${(index + 1).toString().padLeft(2, '0')}';
    }
    if (session.origin == 'delivery') {
      return 'DL${(index + 1).toString().padLeft(2, '0')}';
    }
    if (session.origin == 'self_service') {
      return 'SS${(index + 1).toString().padLeft(2, '0')}';
    }
    return 'M${(index + 1).toString().padLeft(2, '0')}';
  }

  String _resolveZoneName(TableSession session) {
    final zone = session.zoneName;
    if (zone != null && zone.trim().isNotEmpty) {
      return zone.trim();
    }
    return 'Salon Principal';
  }

  @override
  Widget build(BuildContext context) {
    // Excluir mesas virtuales que no son mesas fisicas reales:
    // - 'manual'    → Venta manual (mesa virtual con code 'manual')
    // - 'quick' / 'quick_sale' → Venta rapida (mesa virtual con code 'quick')
    // Ambas existen en dining_tables porque el modelo de orders requiere
    // table_id, pero el dashboard solo deberia mostrar mesas reales del
    // salon. El listado de Ventas Rapidas/Manual vive en la pantalla
    // dedicada de Sales.
    const virtualOrigins = {'manual', 'quick', 'quick_sale'};
    final sessions = viewModel.activeSessions
        .where((s) => !virtualOrigins.contains(s.origin))
        .toList();

    final visibleSessions = isWide
        ? sessions
        : sessions.take(5).toList(growable: false);

    Widget list;
    if (visibleSessions.isEmpty) {
      list = Container(
        height: 200,
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppColors.secondary.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.table_restaurant_outlined,
                size: 32,
                color: AppColors.mutedForeground,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'No hay mesas ocupadas',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Las mesas activas aparecerán aquí',
              style: TextStyle(fontSize: 14, color: AppColors.mutedForeground),
            ),
          ],
        ),
      );
    } else if (isWide && visibleSessions.length > 3) {
      list = ListView.separated(
        itemCount: visibleSessions.length,
        shrinkWrap: false,
        physics: const AlwaysScrollableScrollPhysics(),
        separatorBuilder: (_, index) => const SizedBox(height: 16),
        itemBuilder: (context, index) {
          final s = visibleSessions[index];
          final total = viewModel.sessionTotals[s.id] ?? 0.0;
          final formattedTotal =
              'RD\$ ${NumberFormat('#,##0', 'en_US').format(total)}';
          final duration = AppTime.nowAst().difference(
            AppTime.astFromInstant(s.openedAt),
          );

          return _ActiveTableRow(
            tableCode: _resolveTableCode(s, index),
            zoneName: _resolveZoneName(s),
            peopleCount: s.peopleCount,
            timeStr: _formatDuration(duration),
            formattedTotal: formattedTotal,
            onTap: () => context.go('/sales'),
          );
        },
      );
    } else {
      list = Column(
        children: [
          for (int i = 0; i < visibleSessions.length; i++) ...[
            _ActiveTableRow(
              tableCode: _resolveTableCode(visibleSessions[i], i),
              zoneName: _resolveZoneName(visibleSessions[i]),
              peopleCount: visibleSessions[i].peopleCount,
              timeStr: _formatDuration(
                AppTime.nowAst().difference(
                  AppTime.astFromInstant(visibleSessions[i].openedAt),
                ),
              ),
              formattedTotal:
                  'RD\$ ${NumberFormat('#,##0', 'en_US').format(viewModel.sessionTotals[visibleSessions[i].id] ?? 0.0)}',
              onTap: () => context.go('/sales'),
            ),
            if (i < visibleSessions.length - 1) const SizedBox(height: 16),
          ],
        ],
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border, width: 1),
        boxShadow: AppShadows.soft,
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Mesas Activas',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.foreground,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.warningBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${sessions.length} ocupadas',
                  style: const TextStyle(
                    color: AppColors.warning,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sectionGap),
          if (isWide && visibleSessions.length > 3)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 600),
              child: list,
            )
          else
            list,
          if (sessions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sectionGap),
            Container(height: 1, color: AppColors.border),
            const SizedBox(height: AppSpacing.sectionGap),
            Center(
              child: TextButton(
                onPressed: () => context.go('/sales'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text('Ver todas las mesas'),
                    SizedBox(width: 8),
                    Icon(Icons.arrow_forward, size: 18),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActiveTableRow extends StatelessWidget {
  final String tableCode;
  final String zoneName;
  final int peopleCount;
  final String timeStr;
  final String formattedTotal;
  final VoidCallback onTap;

  const _ActiveTableRow({
    required this.tableCode,
    required this.zoneName,
    required this.peopleCount,
    required this.timeStr,
    required this.formattedTotal,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.secondary.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.warningBg,
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: Text(
                  tableCode,
                  style: const TextStyle(
                    color: AppColors.warning,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      zoneName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppColors.foreground,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Wrap permite que personas/hora salten de línea cuando
                    // el ancho no alcanza (móvil) en vez de overflow.
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.people_outline,
                              size: 14,
                              color: AppColors.mutedForeground,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '$peopleCount personas',
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.access_time,
                              size: 14,
                              color: AppColors.mutedForeground,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              timeStr,
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Text(
                formattedTotal,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
