import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../cashier/viewmodel/cashier_viewmodel.dart';
import 'widgets/hoverable_card.dart';

// Colores base (según HSL del CSS)
const _background = Color(0xFFFAF7F5); // hsl(30 20% 98%)
const _foreground = Color(0xFF221F1E); // hsl(20 14% 12%)
const _card = Color(0xFFFFFFFF); // hsl(0 0% 100%)
const _primary = Color(0xFFF7941A); // hsl(25 95% 53%) - Naranja Mango
const _secondary = Color(0xFFF5F1EE); // hsl(30 15% 95%)
const _muted = Color(0xFFF0EBE7); // hsl(30 10% 92%)
const _accent = Color(0xFFF7F3F0); // hsl(30 20% 94%)
const _success = Color(0xFF10B981); // hsl(142 71% 45%)
const _warning = Color(0xFFFBBF24); // hsl(38 92% 50%)
const _info = Color(0xFF3B82F6); // hsl(217 91% 60%)
const _border = Color(0xFFE8E1DC); // hsl(30 15% 88%)
const _mutedForeground = Color(
  0xFF78716C,
); // Color muted para textos secundarios

class DashboardView extends ConsumerStatefulWidget {
  const DashboardView({super.key});

  @override
  ConsumerState<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends ConsumerState<DashboardView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(cashierViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(cashierViewModelProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SingleChildScrollView(
        // Contenedor principal: padding 1.5rem (p-6), separación vertical 1.5rem (space-y-6)
        padding: const EdgeInsets.all(24), // 1.5rem = 24px
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1) WelcomeCard
            const _WelcomeCard(),
            const SizedBox(height: 24), // space-y-6 = 1.5rem = 24px
            // 2) Grid principal: grid-cols-1 en base; en xl: grid-cols-3
            LayoutBuilder(
              builder: (context, constraints) {
                // en xl: grid-cols-3 con gap 1.5rem (gap-6)
                if (constraints.maxWidth > 1280) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Columna izquierda (xl:col-span-2): space-y-6
                      Expanded(
                        flex: 2,
                        child: Column(
                          children: [
                            const _QuickActionsSection(),
                            const SizedBox(height: 24),
                            _SalesChart(viewModel: vm),
                          ],
                        ),
                      ),
                      const SizedBox(width: 24), // gap-6 = 1.5rem = 24px
                      // Columna derecha: space-y-6
                      Expanded(
                        flex: 1,
                        child: _ActiveTablesWidget(viewModel: vm),
                      ),
                    ],
                  );
                } else {
                  return Column(
                    children: [
                      const _QuickActionsSection(),
                      const SizedBox(height: 24),
                      _ActiveTablesWidget(viewModel: vm),
                      const SizedBox(height: 24),
                      _SalesChart(viewModel: vm),
                    ],
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 1) WelcomeCard
/// - card-elevated + p-6 (1.5rem) + bg-gradient-to-br from-primary/5 via-card to-card
/// - Layout: flex-col en base, lg:flex-row; gap 1.5rem (gap-6)
class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _card, // Solid white background
        borderRadius: BorderRadius.circular(12), // rounded-xl = 0.75rem = 12px
        border: Border.all(color: _border, width: 1),
        boxShadow: [
          // Consistent shadow for all cards
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24), // p-6 = 1.5rem = 24px
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isLarge = constraints.maxWidth > 1024; // lg breakpoint
          return Flex(
            direction: isLarge ? Axis.horizontal : Axis.vertical,
            crossAxisAlignment: isLarge
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Zona izquierda
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Texto fecha: text-sm, text-muted-foreground, capitalize
                    Text(
                      DateFormat(
                        'EEEE, d \'De\' MMMM \'De\' yyyy',
                        'es',
                      ).format(DateTime.now()).toUpperCase(),
                      style: const TextStyle(
                        color: _mutedForeground, // text-muted-foreground
                        fontSize: 14, // text-sm = 0.875rem = 14px
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Título: text-2xl en base, lg:text-3xl; font-bold
                    RichText(
                      text: TextSpan(
                        style: TextStyle(
                          fontSize: isLarge
                              ? 30
                              : 24, // text-3xl = 1.875rem = 30px, text-2xl = 1.5rem = 24px
                          fontWeight: FontWeight.bold,
                          height: 1.2,
                        ),
                        children: const [
                          TextSpan(
                            text: '¡Bienvenido a ',
                            style: TextStyle(color: _foreground),
                          ),
                          TextSpan(
                            text: 'MangoPOS',
                            style: TextStyle(
                              color: _primary,
                            ), // text-gradient-mango
                          ),
                          TextSpan(
                            text: '!',
                            style: TextStyle(color: _foreground),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16), // gap-4 = 1rem = 16px
                    // Meta info: flex-wrap, gap 1rem (gap-4), text-sm, text-muted-foreground
                    Wrap(
                      spacing: 16, // gap-4 = 1rem = 16px
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Indicador estado: punto 8px (w-2 h-2), rounded-full, bg-success, animate-pulse
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: _success,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'Restaurante Demo',
                              style: TextStyle(
                                color: _mutedForeground,
                                fontSize: 14, // text-sm
                              ),
                            ),
                          ],
                        ),
                        const Text(
                          '•',
                          style: TextStyle(color: _mutedForeground),
                        ),
                        const Text(
                          'Usuario: Admin',
                          style: TextStyle(
                            color: _mutedForeground,
                            fontSize: 14,
                          ),
                        ),
                        const Text(
                          '•',
                          style: TextStyle(color: _mutedForeground),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(
                              Icons.attach_money,
                              size: 16,
                              color: _mutedForeground,
                            ),
                            Text(
                              'Caja #001',
                              style: TextStyle(
                                color: _mutedForeground,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!isLarge) const SizedBox(height: 24),
              // Zona derecha
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Badge "Caja cerrada": px-4 py-2; bg-warning/10; rounded-lg; icono 16px
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16, // px-4 = 1rem = 16px
                      vertical: 8, // py-2 = 0.5rem = 8px
                    ),
                    decoration: BoxDecoration(
                      color: _warning.withOpacity(0.1), // bg-warning/10
                      borderRadius: BorderRadius.circular(
                        8,
                      ), // rounded-lg = 0.5rem = 8px
                    ),
                    child: Row(
                      children: const [
                        Icon(
                          Icons.watch_later_outlined,
                          size: 16, // icono 16px
                          color: _warning, // texto warning
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Caja cerrada',
                          style: TextStyle(
                            color: _warning,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Botón "Aperturar Caja": btn-mango (gradiente mango, px-4, py-2.5, rounded-lg, font-semibold)
                  Container(
                    decoration: BoxDecoration(
                      // Gradiente Mango: linear-gradient(135deg, hsl(25 95% 53%) 0%, hsl(35 95% 55%) 100%)
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          _primary, // hsl(25 95% 53%)
                          Color(0xFFFFA726), // hsl(35 95% 55%)
                        ],
                      ),
                      borderRadius: BorderRadius.circular(8), // rounded-lg
                      boxShadow: [
                        BoxShadow(
                          color: _primary.withOpacity(0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {},
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16, // px-4
                            vertical: 10, // py-2.5 = 0.625rem = 10px
                          ),
                          child: Row(
                            children: const [
                              Icon(
                                Icons.attach_money,
                                color: Colors.white,
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Aperturar Caja',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600, // font-semibold
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
          );
        },
      ),
    );
  }
}

/// 2) QuickActions
/// - Grid de acciones rápidas: grid-cols-2 en base, lg:grid-cols-4; gap 1rem (gap-4)
/// - Acciones primarias (grid-cols-2 gap-4, pt-2)
class _QuickActionsSection extends StatelessWidget {
  const _QuickActionsSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Título sección: section-title (text-lg, font-semibold, text-foreground, margin-bottom 1rem)
        const Padding(
          padding: EdgeInsets.only(bottom: 16), // mb-4 = 1rem = 16px
          child: Text(
            'Acciones Rápidas',
            style: TextStyle(
              fontSize: 18, // text-lg = 1.125rem = 18px
              fontWeight: FontWeight.w600, // font-semibold
              color: _foreground,
            ),
          ),
        ),

        // Grid de acciones rápidas: grid-cols-2 en base, lg:grid-cols-4; gap 1rem (gap-4)
        LayoutBuilder(
          builder: (context, constraints) {
            final isLarge = constraints.maxWidth > 1024;
            final count = isLarge ? 4 : 2;
            return GridView.count(
              crossAxisCount: count,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 16, // gap-4 = 1rem = 16px
              crossAxisSpacing: 16,
              childAspectRatio: 2.0, // Adjusted for slightly larger cards
              children: [
                // Mozos: bg-info/10 text-info
                _quickActionCard(
                  context,
                  Icons.people_outline,
                  'Mozos',
                  'Gestionar meseros',
                  _info,
                  '/ajustes/mozos',
                ),
                // Imprimir Productos: bg-success/10 text-success
                _quickActionCard(
                  context,
                  Icons.print_outlined,
                  'Imprimir Productos',
                  'Etiquetas y códigos',
                  _success,
                  '/productos',
                ),
                // Comprobantes: bg-warning/10 text-warning
                _quickActionCard(
                  context,
                  Icons.description_outlined,
                  'Comprobantes',
                  'NCF y facturas',
                  _warning,
                  '/reportes',
                ),
                // Publicidad: bg-primary/10 text-primary
                _quickActionCard(
                  context,
                  Icons.campaign_outlined,
                  'Publicidad',
                  'Promociones activas',
                  _primary,
                  '/ajustes/publicidad',
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 8), // pt-2 = 0.5rem = 8px
        // Acciones primarias (grid-cols-2 gap-4)
        Row(
          children: [
            // "Nueva Venta": card-elevated p-5, bg-gradient-mango, hover:opacity-95
            Expanded(child: _primaryActionNewSale(context)),
            const SizedBox(width: 16), // gap-4 = 1rem = 16px
            // "Delivery": card-interactive p-5
            Expanded(child: _primaryActionDelivery(context)),
          ],
        ),
      ],
    );
  }

  // Tarjetas de acción: card-interactive p-4 (1rem) group
  // Icon box: 40x40 (w-10 h-10), rounded-lg
  // Icono: 20px (w-5 h-5)
  Widget _quickActionCard(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    Color color,
    String route,
  ) {
    return HoverableCard(
      onTap: () => GoRouter.of(context).go(route),
      child: Container(
        padding: const EdgeInsets.all(14), // p-4 slightly reduced
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(15), // 15px border radius
          border: Border.all(color: _border, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon box: 40x40 (w-10 h-10)
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10), // rounded-lg
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                color: color,
                size: 20, // w-5 h-5 = 20px
              ),
            ),
            const SizedBox(height: 10),
            // Title
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: _foreground,
              ),
            ),
            const SizedBox(height: 2),
            // Subtitle
            Text(
              subtitle,
              style: const TextStyle(color: _mutedForeground, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  // "Nueva Venta": card-elevated p-5, flex, gap-4, bg-gradient-mango
  // Icon box: 48x48 (w-12 h-12), rounded-xl, bg-primary-foreground/20; icon 24px (w-6 h-6)
  Widget _primaryActionNewSale(BuildContext context) {
    return HoverableCard(
      onTap: () => GoRouter.of(context).go('/ventas'),
      child: Container(
        padding: const EdgeInsets.all(20), // p-5 = 1.25rem = 20px
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_primary, Color(0xFFFFA726)],
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Icon box: 48x48 (w-12 h-12), rounded-xl, bg-primary-foreground/20
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(
                  0.2,
                ), // bg-primary-foreground/20
                borderRadius: BorderRadius.circular(12), // rounded-xl
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.add,
                color: Colors.white,
                size: 24, // w-6 h-6 = 1.5rem = 24px
              ),
            ),
            const SizedBox(width: 16), // gap-4 = 1rem = 16px
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Text(
                  'Nueva Venta',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Ir al punto de venta',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // "Delivery": card-interactive p-5, flex, gap-4
  // Icon box: 48x48, rounded-xl, bg-info/10; icon 24px color info
  Widget _primaryActionDelivery(BuildContext context) {
    return HoverableCard(
      onTap: () => GoRouter.of(context).go('/ventas?mode=delivery'),
      child: Container(
        padding: const EdgeInsets.all(20), // p-5
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border, width: 1),
          boxShadow: [
            BoxShadow(
              color: _foreground.withOpacity(0.05),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
            BoxShadow(
              color: _foreground.withOpacity(0.08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // Icon box: 48x48, rounded-xl, bg-info/10
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _info.withOpacity(0.1), // bg-info/10
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.shopping_bag_outlined,
                color: _info,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Text(
                  'Delivery',
                  style: TextStyle(
                    color: _foreground,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Pedidos para entrega',
                  style: TextStyle(color: _mutedForeground, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 3) SalesChart - MANTIENE BACKEND COMPLETO
/// - card-elevated p-6
/// - Stats row: grid-cols-3 gap-4; mb-6
/// - Stat cards: p-4, rounded-xl, border 1px
/// - Chart: altura fija 16rem (h-64)
class _SalesChart extends StatelessWidget {
  final CashierViewModel viewModel;
  const _SalesChart({required this.viewModel});

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.simpleCurrency(name: 'DOP');

    final List<FlSpot> spots = [];
    if (viewModel.weeklySales.isNotEmpty) {
      for (int i = 0; i < viewModel.weeklySales.length; i++) {
        spots.add(FlSpot(i.toDouble(), viewModel.weeklySales[i]));
      }
    } else {
      spots.addAll(List.generate(7, (i) => FlSpot(i.toDouble(), 0)));
    }

    double maxY = 100;
    for (var spot in spots) {
      if (spot.y > maxY) maxY = spot.y * 1.2;
    }

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12), // rounded-xl
        border: Border.all(color: _border, width: 1),
        boxShadow: [
          BoxShadow(
            color: _foreground.withOpacity(0.05),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: _foreground.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24), // p-6 = 1.5rem = 24px
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: flex-col en base; sm:flex-row; gap 1rem; mb-6
          LayoutBuilder(
            builder: (context, constraints) {
              final isSm = constraints.maxWidth > 640;
              return Flex(
                direction: isSm ? Axis.horizontal : Axis.vertical,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'Resumen de Ventas',
                        style: TextStyle(
                          fontSize: 18, // text-lg
                          fontWeight: FontWeight.w600,
                          color: _foreground,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Últimos 7 días',
                        style: TextStyle(
                          color: _mutedForeground,
                          fontSize: 14, // text-sm
                        ),
                      ),
                    ],
                  ),
                  if (!isSm) const SizedBox(height: 16),
                  // Botón "Esta semana": px-4 py-2, bg-secondary, rounded-lg
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16, // px-4
                      vertical: 8, // py-2
                    ),
                    decoration: BoxDecoration(
                      color: _secondary, // bg-secondary
                      borderRadius: BorderRadius.circular(8), // rounded-lg
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          Icons.calendar_today_rounded,
                          size: 14,
                          color: _foreground,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Esta semana',
                          style: TextStyle(
                            fontSize: 14, // text-sm
                            fontWeight: FontWeight.w500, // font-medium
                            color: _foreground,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 24), // mb-6 = 1.5rem = 24px
          // Stats row: grid-cols-3 gap-4; mb-6
          Row(
            children: [
              // Total Ventas: bg-success/5, border-success/20, texto success
              _statCard(
                'Total Ventas',
                currency.format(viewModel.totalWeeklySales),
                _success.withOpacity(0.05), // bg-success/5
                _success.withOpacity(0.2), // border-success/20
                _success,
              ),
              const SizedBox(width: 16), // gap-4
              // Promedio Diario: bg-info/5, border-info/20, texto info
              _statCard(
                'Promedio Diario',
                currency.format(viewModel.weeklyAverage),
                _info.withOpacity(0.05),
                _info.withOpacity(0.2),
                _info,
              ),
              const SizedBox(width: 16),
              // Día Récord: bg-primary/5, border-primary/20, texto primary
              _statCard(
                'Día Récord',
                currency.format(viewModel.bestDayAmount),
                _primary.withOpacity(0.05),
                _primary.withOpacity(0.2),
                _primary,
              ),
            ],
          ),
          const SizedBox(height: 24), // mb-6
          // Chart: altura fija 16rem (h-64)
          SizedBox(
            height: 256, // h-64 = 16rem = 256px
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: maxY / 4,
                  getDrawingHorizontalLine: (value) {
                    return FlLine(
                      color: _border.withOpacity(0.5),
                      strokeWidth: 1,
                    );
                  },
                ),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: 1,
                      getTitlesWidget: (val, meta) {
                        const days = [
                          'Lun',
                          'Mar',
                          'Mié',
                          'Jue',
                          'Vie',
                          'Sáb',
                          'Dom',
                        ];
                        if (val.toInt() >= 0 && val.toInt() < days.length) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: Text(
                              days[val.toInt()],
                              style: const TextStyle(
                                fontSize: 12, // text-xs
                                color: _mutedForeground,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          );
                        }
                        return const SizedBox();
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: maxY / 4,
                      reservedSize: 40,
                      getTitlesWidget: (val, meta) {
                        if (val == 0) return const SizedBox.shrink();
                        return Text(
                          '${(val / 1000).toStringAsFixed(0)}k',
                          style: const TextStyle(
                            fontSize: 12, // text-xs
                            color: _mutedForeground,
                          ),
                        );
                      },
                    ),
                  ),
                  topTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                borderData: FlBorderData(show: false),
                minX: 0,
                maxX: 6,
                minY: 0,
                maxY: maxY,
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (touchedSpot) => _card,
                    tooltipPadding: const EdgeInsets.all(12),
                    tooltipBorder: BorderSide(color: _border, width: 1),
                    getTooltipItems: (touchedSpots) {
                      return touchedSpots.map((spot) {
                        const days = [
                          'Lun',
                          'Mar',
                          'Mié',
                          'Jue',
                          'Vie',
                          'Sáb',
                          'Dom',
                        ];
                        final day = days[spot.x.toInt()];
                        return LineTooltipItem(
                          '$day\n',
                          const TextStyle(
                            color: _foreground,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          children: [
                            TextSpan(
                              text: currency.format(spot.y),
                              style: const TextStyle(
                                color: _primary,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        );
                      }).toList();
                    },
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    curveSmoothness: 0.35,
                    color: _primary,
                    barWidth: 3,
                    isStrokeCapRound: true,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, percent, barData, index) {
                        return FlDotCirclePainter(
                          radius: 4,
                          color: _card,
                          strokeWidth: 2,
                          strokeColor: _primary,
                        );
                      },
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          _primary.withOpacity(0.15),
                          _primary.withOpacity(0.01),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Trend indicator: mt-4 pt-4 con border-t
          Container(
            margin: const EdgeInsets.only(top: 16), // mt-4 = 1rem = 16px
            padding: const EdgeInsets.only(top: 16), // pt-4
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _border, width: 1)),
            ),
            child: Row(
              children: [
                const Icon(Icons.trending_up, size: 16, color: _success),
                const SizedBox(width: 6),
                const Text(
                  '+12.5%',
                  style: TextStyle(
                    color: _success,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  'vs. semana anterior',
                  style: TextStyle(color: _mutedForeground, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Stat cards: p-4, rounded-xl, border 1px
  // Textos: label text-xs muted; valor text-xl font-bold
  Widget _statCard(
    String label,
    String value,
    Color bgColor,
    Color borderColor,
    Color textColor,
  ) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16), // p-4 = 1rem = 16px
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12), // rounded-xl
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: _mutedForeground, // text-xs muted
                fontSize: 12, // text-xs
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.bold, // font-bold
                fontSize: 20, // text-xl = 1.25rem = 20px
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 4) ActiveTablesWidget
/// - card-elevated p-6
/// - Badge ocupadas: badge-warning (px-2.5 py-1, rounded-full)
/// - Item de mesa: p-3 (0.75rem); bg-secondary/50; rounded-xl
/// - Icon box: 40x40 (w-10 h-10), bg-warning/10, rounded-lg
class _ActiveTablesWidget extends StatelessWidget {
  final CashierViewModel viewModel;
  const _ActiveTablesWidget({required this.viewModel});

  @override
  Widget build(BuildContext context) {
    final sessions = viewModel.activeSessions;

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border, width: 1),
        boxShadow: [
          BoxShadow(
            color: _foreground.withOpacity(0.05),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: _foreground.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24), // p-6
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: flex items-center justify-between; mb-4
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Mesas Activas',
                style: TextStyle(
                  fontSize: 18, // text-lg
                  fontWeight: FontWeight.w600,
                  color: _foreground,
                ),
              ),
              // Badge ocupadas: px-2.5 py-1, rounded-full, bg-warning/10, text-warning
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10, // px-2.5 = 0.625rem = 10px
                  vertical: 4, // py-1 = 0.25rem = 4px
                ),
                decoration: BoxDecoration(
                  color: _warning.withOpacity(0.1), // bg-warning/10
                  borderRadius: BorderRadius.circular(9999), // rounded-full
                ),
                child: Text(
                  '${sessions.length} ocupadas',
                  style: const TextStyle(
                    color: _warning,
                    fontSize: 12, // text-xs
                    fontWeight: FontWeight.w500, // font-medium
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16), // mb-4 = 1rem = 16px

          if (sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'No hay mesas ocupadas',
                  style: TextStyle(color: _mutedForeground),
                ),
              ),
            )
          else
            // Lista de mesas: space-y-3
            ListView.separated(
              itemCount: sessions.take(5).length,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              separatorBuilder: (_, __) =>
                  const SizedBox(height: 12), // space-y-3 = 0.75rem = 12px
              itemBuilder: (context, index) {
                final s = sessions[index];
                final duration = DateTime.now().difference(s.openedAt);
                final hours = duration.inHours;
                final minutes = duration.inMinutes % 60;

                return HoverableCard(
                  child: Container(
                    // Item de mesa: p-3 (0.75rem); bg-secondary/50; rounded-xl
                    padding: const EdgeInsets.all(12), // p-3 = 0.75rem = 12px
                    decoration: BoxDecoration(
                      color: _secondary.withOpacity(0.5), // bg-secondary/50
                      borderRadius: BorderRadius.circular(12), // rounded-xl
                    ),
                    child: Row(
                      children: [
                        // Icon box: 40x40 (w-10 h-10), bg-warning/10, rounded-lg
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: _warning.withOpacity(0.1), // bg-warning/10
                            borderRadius: BorderRadius.circular(
                              8,
                            ), // rounded-lg
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            s.customerName != null && s.customerName!.isNotEmpty
                                ? s.customerName!
                                      .substring(
                                        0,
                                        s.customerName!.length > 4
                                            ? 4
                                            : s.customerName!.length,
                                      )
                                      .toUpperCase()
                                : 'SP${(index + 1).toString().padLeft(2, '0')}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: _warning, // texto warning
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.origin == 'dine_in'
                                    ? 'Salón Principal'
                                    : 'Terraza',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: _foreground,
                                ),
                              ),
                              const SizedBox(height: 4),
                              // Meta: texto xs muted con iconos 12px (w-3 h-3)
                              Row(
                                children: [
                                  const Icon(
                                    Icons.people_outline,
                                    size: 12, // w-3 h-3 = 0.75rem = 12px
                                    color: _mutedForeground,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${s.peopleCount} personas',
                                    style: const TextStyle(
                                      fontSize: 12, // text-xs
                                      color: _mutedForeground,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const Icon(
                                    Icons.access_time,
                                    size: 12,
                                    color: _mutedForeground,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${hours}:${minutes.toString().padLeft(2, '0')}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: _mutedForeground,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        // Total: texto bold en foreground
                        const Text(
                          'RD\$ 2,850',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: _foreground,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

          // Footer link: mt-4 pt-4, border-t; icono 16px
          Container(
            margin: const EdgeInsets.only(top: 16), // mt-4
            padding: const EdgeInsets.only(top: 16), // pt-4
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _border, width: 1)),
            ),
            child: Center(
              child: TextButton(
                onPressed: () {},
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text(
                      'Ver todas las mesas',
                      style: TextStyle(
                        color: _primary, // texto primary
                        fontWeight: FontWeight.w500, // font-medium
                        fontSize: 14,
                      ),
                    ),
                    SizedBox(width: 6),
                    Icon(
                      Icons.arrow_forward,
                      size: 16, // icono 16px
                      color: _primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
