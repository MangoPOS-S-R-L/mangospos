import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DashboardView extends StatelessWidget {
  const DashboardView({super.key});

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          // ------ Header con usuario, rol, UID y Business ID ------
          const _UserHeader(),
          const SizedBox(height: 12),

          Text('Dashboard', style: title),
          const SizedBox(height: 16),

          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: const [
              KpiCard(title: 'Ventas Hoy', value: '\$2,430'),
              KpiCard(title: 'Tickets', value: '128'),
              KpiCard(title: 'Ticket Promedio', value: '\$19.0'),
              KpiCard(title: 'Productos Top', value: '3'),
            ],
          ),

          const SizedBox(height: 24),

          LayoutBuilder(
            builder: (context, c) {
              final twoCols = c.maxWidth > 1000;
              return Flex(
                direction: twoCols ? Axis.horizontal : Axis.vertical,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: ChartCard(
                      title: 'Ventas por hora',
                      child: SizedBox(height: 260, child: _lineSalesByHour()),
                    ),
                  ),
                  const SizedBox(width: 16, height: 16),
                  Expanded(
                    flex: 2,
                    child: ChartCard(
                      title: 'Top Categorías',
                      child: SizedBox(height: 260, child: _barTopCategories()),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ---- Charts ----
  static Widget _lineSalesByHour() {
    final points = <FlSpot>[
      const FlSpot(8, 120),
      const FlSpot(9, 90),
      const FlSpot(10, 150),
      const FlSpot(11, 190),
      const FlSpot(12, 320),
      const FlSpot(13, 280),
      const FlSpot(14, 210),
      const FlSpot(15, 180),
      const FlSpot(16, 260),
      const FlSpot(17, 400),
      const FlSpot(18, 520),
      const FlSpot(19, 610),
      const FlSpot(20, 560),
      const FlSpot(21, 430),
    ];
    return LineChart(
      LineChartData(
        minX: 8,
        maxX: 21,
        minY: 0,
        maxY: 650,
        gridData: FlGridData(show: true, drawVerticalLine: false),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 2,
              getTitlesWidget: (v, _) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${v.toInt()}h',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 200,
              getTitlesWidget: (v, _) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '\$${v.toInt()}',
                  style: const TextStyle(fontSize: 11),
                ),
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
            isCurved: true,
            spots: points,
            barWidth: 3,
            dotData: const FlDotData(show: false),
          ),
        ],
      ),
    );
  }

  static Widget _barTopCategories() {
    final bars = <BarChartGroupData>[
      _bar(0, 45, 'Bebidas'),
      _bar(1, 38, 'Platos'),
      _bar(2, 26, 'Postres'),
      _bar(3, 22, 'Entradas'),
    ];
    return BarChart(
      BarChartData(
        barGroups: bars,
        gridData: FlGridData(
          show: true,
          drawHorizontalLine: true,
          horizontalInterval: 10,
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 10,
              getTitlesWidget: (v, _) => Text(
                v.toInt().toString(),
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, _) {
                const labels = ['Bebidas', 'Platos', 'Postres', 'Entradas'];
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    labels[v.toInt()],
                    style: const TextStyle(fontSize: 11),
                  ),
                );
              },
            ),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
      ),
    );
  }

  static BarChartGroupData _bar(int x, double y, String _) => BarChartGroupData(
    x: x,
    barRods: [
      BarChartRodData(
        toY: y,
        width: 20,
        borderRadius: BorderRadius.circular(6),
      ),
    ],
  );
}

/// --- Header: lee Nombre/Apellido (profiles), UID (auth) y Business ID (memberships/user_businesses) ---
class _UserHeader extends StatelessWidget {
  const _UserHeader();

  Future<_UserInfo> _loadUserInfo() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;

    if (user == null) {
      return const _UserInfo(
        firstName: 'Invitado',
        lastName: '',
        roleLabel: 'Sin sesión',
        uid: '—',
        businessId: '—',
      );
    }

    // 1) PERFIL: intenta varias columnas/tabl as
    final profileCandidates = <({String table, List<String> cols})>[
      (
        table: 'profiles',
        cols: ['first_name', 'last_name', 'full_name', 'name', 'role'],
      ),
      (
        table: 'users',
        cols: ['first_name', 'last_name', 'full_name', 'name', 'role'],
      ),
      (
        table: 'staff_profiles',
        cols: ['first_name', 'last_name', 'name', 'role'],
      ),
    ];

    Map<String, dynamic>? profile;
    for (final c in profileCandidates) {
      try {
        final data = await supabase
            .from(c.table)
            .select(c.cols.join(', '))
            .eq('user_id', user.id) // ajusta si tu PK es distinta
            .maybeSingle();
        if (data != null) {
          profile = data;
          break;
        }
      } catch (_) {
        // sigue probando
      }
    }

    // Arma nombre y apellido
    String? fn = (profile?['first_name'] ?? user.userMetadata?['first_name'])
        ?.toString();
    String? ln = (profile?['last_name'] ?? user.userMetadata?['last_name'])
        ?.toString();

    if ((fn == null || fn.isEmpty) || (ln == null || ln.isEmpty)) {
      final possibleFull =
          (profile?['full_name'] ??
                  profile?['name'] ??
                  user.userMetadata?['name'] ??
                  user.email ??
                  'Usuario')
              .toString()
              .trim();
      final parts = possibleFull.split(RegExp(r'\s+'));
      if (parts.isNotEmpty) {
        fn ??= parts.first;
        ln ??= parts.length > 1 ? parts.last : '';
      }
    }

    // Rol legible
    final rawRole = (profile?['role'] ?? user.userMetadata?['role'] ?? 'admin')
        .toString();
    final roleLabel = switch (rawRole.toLowerCase()) {
      'admin' || 'administrator' => 'Administrador del Sistema',
      'cashier' || 'cajero' => 'Cajero',
      'waiter' || 'mozo' || 'mesero' => 'Mesero',
      'kitchen' || 'chef' => 'Cocina',
      'manager' || 'gerente' => 'Gerente',
      _ => rawRole,
    };

    // 2) BUSINESS ID: primero en memberships, si no, user_businesses
    String businessId = '—';
    try {
      final m = await supabase
          .from('memberships')
          .select('business_id, user_id')
          .eq('user_id', user.id)
          .order('created_at', ascending: true)
          .limit(1)
          .maybeSingle();
      if (m != null && m['business_id'] != null) {
        businessId = m['business_id'].toString();
      }
    } catch (_) {
      // intentar user_businesses
    }

    if (businessId == '—') {
      try {
        final ub = await supabase
            .from('user_businesses')
            .select('business_id, user_id')
            .eq('user_id', user.id)
            .order('created_at', ascending: true)
            .limit(1)
            .maybeSingle();
        if (ub != null && ub['business_id'] != null) {
          businessId = ub['business_id'].toString();
        }
      } catch (_) {
        // sin business id
      }
    }

    return _UserInfo(
      firstName: (fn ?? 'Usuario').trim(),
      lastName: (ln ?? '').trim(),
      roleLabel: roleLabel,
      uid: user.id,
      businessId: businessId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final grey = Colors.grey[700];

    return FutureBuilder<_UserInfo>(
      future: _loadUserInfo(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text('Cargando usuario...', style: text.bodyMedium),
            ],
          );
        }
        if (snap.hasError || snap.data == null) {
          return Text(
            'No se pudo cargar el usuario',
            style: text.bodyMedium?.copyWith(color: Colors.red),
          );
        }

        final info = snap.data!;
        return Row(
          children: [
            CircleAvatar(
              radius: 18,
              child: Text(
                info.initials,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.fullName,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  info.roleLabel,
                  style: text.bodySmall?.copyWith(color: grey),
                ),
                const SizedBox(height: 2),
                // Línea con UID y Business ID
                Row(
                  children: [
                    Text('UID: ', style: text.bodySmall?.copyWith(color: grey)),
                    SelectableText(
                      info.uid,
                      style: text.bodySmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Business: ',
                      style: text.bodySmall?.copyWith(color: grey),
                    ),
                    SelectableText(
                      info.businessId,
                      style: text.bodySmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _UserInfo {
  final String firstName;
  final String lastName;
  final String roleLabel;
  final String uid;
  final String businessId;

  const _UserInfo({
    required this.firstName,
    required this.lastName,
    required this.roleLabel,
    required this.uid,
    required this.businessId,
  });

  String get fullName {
    final fn = firstName.trim();
    final ln = lastName.trim();
    if (ln.isEmpty) return fn;
    return '$fn $ln';
  }

  String get initials {
    final fn = firstName.isNotEmpty ? firstName[0] : '';
    final ln = lastName.isNotEmpty ? lastName[0] : '';
    final combo = (fn + ln).trim();
    return (combo.isEmpty ? 'U' : combo.toUpperCase());
  }
}

/// ===== Widgets públicos =====

class KpiCard extends StatelessWidget {
  final String title;
  final String value;
  const KpiCard({super.key, required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Card(
        elevation: 0.5,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Text(
                value,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChartCard extends StatelessWidget {
  final String title;
  final Widget child;
  const ChartCard({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0.5,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
