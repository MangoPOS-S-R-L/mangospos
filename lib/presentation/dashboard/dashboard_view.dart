import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DashboardView extends StatelessWidget {
  const DashboardView({super.key});

  static const _brandOrange = Color(0xFFF7941A);
  static const _brandGreen = Color(0xFF66BB6A);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, // White background
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Header & Welcome
            const _WelcomeHeader(),
            const SizedBox(height: 24),

            // 2. Quick Actions Row
            const _QuickActionsRow(),
            const SizedBox(height: 24),

            // 3. Sales Summary (Chart)
            const _SalesSummarySection(),
            const SizedBox(height: 24),

            // 4. KPI Cards & Pie Chart
            const _KpiAndPieSection(),
            const SizedBox(height: 24),

            // 5. "Más sobre mi negocio"
            Text(
              'Más sobre mi negocio',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 16),
            const _BusinessInsightsSection(),

            const SizedBox(height: 24),
            // 6. Top Products
            const _TopProductsSection(),
          ],
        ),
      ),
    );
  }
}

/// 1. Header: Welcome, User Info, Open Register Button
class _WelcomeHeader extends StatelessWidget {
  const _WelcomeHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '¡Bienvenido a tu Plan Profesional!',
                  style: TextStyle(
                    color: DashboardView._brandOrange,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 8),
                const _AsyncUserInfo(),
              ],
            ),
          ),
          ElevatedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.point_of_sale, color: Colors.white),
            label: const Text(
              'Aperturar tu caja',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: DashboardView._brandGreen,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AsyncUserInfo extends StatelessWidget {
  const _AsyncUserInfo();

  Future<Map<String, String>> _loadUser() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      return {'name': 'Usuario', 'code': '---'};
    }

    try {
      // 1. Intentar obtener del metadata
      String name =
          user.userMetadata?['name'] ?? user.userMetadata?['full_name'] ?? '';

      // 2. Si no está, buscar en tabla profiles
      if (name.isEmpty) {
        final response = await Supabase.instance.client
            .from('profiles')
            .select('full_name')
            .eq('id', user.id)
            .maybeSingle();

        if (response != null) {
          name = response['full_name'] as String? ?? '';
        }
      }

      // 3. Fallback
      if (name.isEmpty) {
        name = 'Usuario';
      }

      return {
        'name': name,
        'code': 'ND5R3B', // TODO: Fetch real code if available
      };
    } catch (e) {
      return {'name': user.email ?? 'Usuario', 'code': 'ND5R3B'};
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _loadUser(),
      builder: (context, snapshot) {
        final name = snapshot.data?['name'] ?? 'Cargando...';
        final code = snapshot.data?['code'] ?? '...';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            Text(
              'CÓDIGO DE CAJA: $code',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: DashboardView._brandOrange,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 2. Quick Actions Row
class _QuickActionsRow extends StatelessWidget {
  const _QuickActionsRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _actionItem(context, Icons.person, 'Mozos', true),
        const SizedBox(width: 16),
        _actionItem(context, Icons.print, 'Imprimir productos', false),
        const SizedBox(width: 16),
        _actionItem(context, Icons.receipt, 'Imprimir comprobantes', false),
        const SizedBox(width: 16),
        _actionItem(context, Icons.campaign, 'Publicidad', false),
      ],
    );
  }

  Widget _actionItem(
    BuildContext context,
    IconData icon,
    String label,
    bool isActive,
  ) {
    return Expanded(
      child: Container(
        height: 80,
        decoration: BoxDecoration(
          color: isActive ? DashboardView._brandOrange : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive ? Colors.transparent : Colors.grey.shade200,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isActive ? Colors.white : Colors.grey[700]),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.white : Colors.grey[700],
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 3. Sales Summary Section
class _SalesSummarySection extends StatelessWidget {
  const _SalesSummarySection();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Resumen',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: DashboardView._brandOrange,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Observa tus ventas por:'),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: const [
                    Icon(Icons.calendar_today, size: 16, color: Colors.grey),
                    SizedBox(width: 8),
                    Text('27 Nov. 2025 al 4 Dic. 2025'),
                    Icon(Icons.arrow_drop_down, color: Colors.grey),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Chart & Total
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Gráfico por cantidad de ventas'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _legendItem(
                          DashboardView._brandOrange,
                          'Esta semana: +100%',
                        ),
                        const SizedBox(width: 16),
                        _legendItem(Colors.red, 'Semana pasada: 0%'),
                      ],
                    ),
                    const SizedBox(height: 24),
                    SizedBox(height: 250, child: _SalesLineChart()),
                  ],
                ),
              ),
              const SizedBox(width: 48),
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'TOTAL DE VENTAS',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'RD\$11,680.50',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: DashboardView._brandOrange,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legendItem(Color color, String text) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(text, style: TextStyle(color: Colors.grey[700], fontSize: 12)),
      ],
    );
  }
}

class _SalesLineChart extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final points = [
      const FlSpot(15, 1),
      const FlSpot(16, 4),
      const FlSpot(18, 2),
    ];

    return LineChart(
      LineChartData(
        minX: 15,
        maxX: 18,
        minY: 0,
        maxY: 5,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: true,
          getDrawingHorizontalLine: (value) =>
              FlLine(color: Colors.grey.withOpacity(0.1), strokeWidth: 1),
          getDrawingVerticalLine: (value) =>
              FlLine(color: Colors.grey.withOpacity(0.1), strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: (v, _) => Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  '${v.toInt()}:00',
                  style: const TextStyle(color: Colors.grey, fontSize: 10),
                ),
              ),
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              reservedSize: 30,
              getTitlesWidget: (v, _) => Text(
                v.toInt().toString(),
                style: const TextStyle(color: Colors.grey, fontSize: 10),
              ),
            ),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: true,
            color: DashboardView._brandOrange,
            barWidth: 2,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, barData, index) =>
                  FlDotCirclePainter(
                    radius: 4,
                    color: Colors.white,
                    strokeWidth: 2,
                    strokeColor: DashboardView._brandOrange,
                  ),
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  DashboardView._brandOrange.withOpacity(0.2),
                  DashboardView._brandOrange.withOpacity(0.0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 4. KPI Grid & Pie Chart
class _KpiAndPieSection extends StatelessWidget {
  const _KpiAndPieSection();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Grid of 6 cards
        Expanded(
          flex: 3,
          child: Column(
            children: [
              Row(
                children: const [
                  Expanded(
                    child: _MiniKpiCard(
                      title: 'Ventas en efectivo',
                      value: 'RD\$5,896.00',
                      subValue: 'Redondeo RD\$2.10',
                      color: DashboardView._brandOrange,
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: _MiniKpiCard(
                      title: 'Ventas con tarjeta',
                      value: 'RD\$3,782.40',
                      color: DashboardView._brandOrange,
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: _MiniKpiCard(
                      title: 'Ventas en línea + vales',
                      value: 'RD\$0.00',
                      color: DashboardView._brandOrange,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: const [
                  Expanded(
                    child: _MiniKpiCard(
                      title: 'Total de egresos de caja',
                      value: 'RD\$1,000.00',
                      color: Colors.purple,
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: _MiniKpiCard(
                      title: 'Ventas al crédito',
                      value: 'RD\$0.00',
                      subValue: 'Intereses RD\$0.00',
                      color: DashboardView._brandOrange,
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: _MiniKpiCard(
                      title: 'Total de descuentos',
                      value: 'RD\$0.00',
                      color: DashboardView._brandOrange,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 24),
        // Pie Chart
        Expanded(
          flex: 1,
          child: Container(
            height: 240, // Match approx height of 2 rows
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Atención en general',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Expanded(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          sectionsSpace: 0,
                          centerSpaceRadius: 40,
                          sections: [
                            PieChartSectionData(
                              color: DashboardView._brandGreen,
                              value: 83.33,
                              title: '83.33%',
                              radius: 25,
                              titleStyle: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                              ),
                            ),
                            PieChartSectionData(
                              color: DashboardView._brandOrange,
                              value: 16.67,
                              title: '16.67%',
                              radius: 25,
                              titleStyle: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Text(
                        'Total',
                        style: TextStyle(fontSize: 10, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                // Legend
                Column(
                  children: [
                    _pieLegend(DashboardView._brandGreen, 'Bueno'),
                    _pieLegend(DashboardView._brandOrange, 'Regular'),
                    _pieLegend(Colors.red, 'Malo'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _pieLegend(Color color, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          CircleAvatar(radius: 4, backgroundColor: color),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}

class _MiniKpiCard extends StatelessWidget {
  final String title;
  final String value;
  final String? subValue;
  final Color color;

  const _MiniKpiCard({
    required this.title,
    required this.value,
    this.subValue,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 110,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.payment, size: 16, color: color), // Placeholder icon
                const SizedBox(height: 8),
                Text(
                  title,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
          // Mini Sparkline
          SizedBox(
            width: 60,
            height: 40,
            child: LineChart(
              LineChartData(
                gridData: FlGridData(show: false),
                titlesData: FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: const [
                      FlSpot(0, 1),
                      FlSpot(1, 3),
                      FlSpot(2, 2),
                      FlSpot(3, 4),
                      FlSpot(4, 3),
                    ],
                    isCurved: true,
                    color: color,
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 5. Business Insights Section
class _BusinessInsightsSection extends StatelessWidget {
  const _BusinessInsightsSection();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Simple responsive grid
        final width = constraints.maxWidth;
        final isWide = width > 1000;

        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            // Mozo del dia
            _CardContainer(
              width: isWide ? (width - 48) / 4 : (width - 16) / 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Icon(
                        Icons.emoji_events,
                        color: DashboardView._brandOrange,
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: DashboardView._brandOrange,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Ranking diario',
                          style: TextStyle(color: Colors.white, fontSize: 10),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'MOZO DEL DÍA',
                    style: TextStyle(
                      fontSize: 10,
                      color: DashboardView._brandOrange,
                    ),
                  ),
                  const Text(
                    'Frank Rodriguez',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    color: DashboardView._brandOrange,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          '19 PEDIDOS',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '68.15% de las ventas',
                          style: TextStyle(color: Colors.white70, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Clientes
            _CardContainer(
              width: isWide ? (width - 48) / 4 : (width - 16) / 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: const [
                      Icon(
                        Icons.people,
                        color: DashboardView._brandOrange,
                        size: 18,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Clientes',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: DashboardView._brandOrange,
                        ),
                      ),
                    ],
                  ),
                  const Divider(),
                  const Text(
                    'Total de clientes',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  const Text(
                    '7',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              'Empresas',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                              ),
                            ),
                            Text(
                              '0',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              'Personas',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                              ),
                            ),
                            Text(
                              '7',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Ticket Promedio
            _CardContainer(
              width: isWide
                  ? (width - 48) / 2
                  : width, // Takes 2 slots or full width
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: const [
                      Icon(
                        Icons.receipt_long,
                        color: DashboardView._brandOrange,
                        size: 18,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Ticket promedio de venta',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: DashboardView._brandOrange,
                        ),
                      ),
                    ],
                  ),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              'Por venta',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                            Text(
                              'RD\$1,668.64',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'en 7 ventas',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 40,
                        color: Colors.grey.shade300,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              'Por persona',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                            Text(
                              'RD\$1,668.64',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Afluencia 7 personas',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CardContainer extends StatelessWidget {
  final Widget child;
  final double width;

  const _CardContainer({required this.child, required this.width});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 180,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 5,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 6. Top Products Section
class _TopProductsSection extends StatelessWidget {
  const _TopProductsSection();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Top 10 productos más vendidos en mi local',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // #1 Product Card
              Container(
                width: 200,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [
                        Text(
                          '#1',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: DashboardView._brandOrange,
                          ),
                        ),
                        Icon(Icons.emoji_events, color: Colors.amber),
                      ],
                    ),
                    const Text(
                      'PRODUCTO TOP',
                      style: TextStyle(
                        fontSize: 10,
                        color: DashboardView._brandOrange,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Agua Personal',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(8),
                      color: DashboardView._brandOrange,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: const [
                          Text(
                            '4 VENTAS\nRD\$251.00',
                            style: TextStyle(color: Colors.white, fontSize: 10),
                          ),
                          Icon(Icons.arrow_drop_up, color: Colors.white),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              // List of other products
              Expanded(
                child: Column(
                  children: [
                    _productRow(
                      '#2',
                      'Burrito de Carne',
                      '3.00 VENTAS',
                      'RD\$2,150.40',
                    ),
                    const Divider(),
                    _productRow(
                      '#3',
                      'Batido De Fresa',
                      '2.00 VENTAS',
                      'RD\$576.00',
                    ),
                    const Divider(),
                    _productRow(
                      '#4',
                      'Batida de Zapote',
                      '2.00 VENTAS',
                      'RD\$430.50',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _productRow(String rank, String name, String sales, String total) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Text(
            rank,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: DashboardView._brandOrange,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Text(sales, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(width: 16),
          Text(total, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
