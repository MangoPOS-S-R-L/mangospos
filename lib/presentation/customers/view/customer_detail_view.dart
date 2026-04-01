import 'package:flutter/material.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_spacing.dart';

class CustomerDetailView extends StatelessWidget {
  final String customerName;
  final int ordersCount;

  const CustomerDetailView({
    super.key,
    required this.customerName,
    required this.ordersCount,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.card,
      appBar: AppBar(
        title: const Text(
          'Pedidos',
          style: TextStyle(color: AppColors.foreground, fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.card,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.foreground),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Text(
                  customerName,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    '$ordersCount PEDIDOS',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
                const Spacer(),
                const Text(
                  'Total: \$75.000',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppColors.foreground,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xxxl),

            // Orders Grid
            LayoutBuilder(
              builder: (context, constraints) {
                return Wrap(
                  spacing: AppSpacing.xxl,
                  runSpacing: AppSpacing.xxl,
                  children: [
                    _buildOrderCard(
                      orderId: '#545',
                      status: 'Entregado',
                      statusColor: AppColors.success,
                      statusLabel: 'VERIFICACIÓN DE PAGO',
                      statusLabelColor: AppColors.primary,
                      date: 'octubre 21, 2025 13:51 p. m.',
                      items: '1 Elemento(s)',
                      total: '\$25.000',
                      icon: Icons.shopping_bag_outlined,
                      iconBg: AppColors.secondary,
                    ),
                    _buildOrderCard(
                      orderId: '#545',
                      status: 'Pedido Cancelado',
                      statusColor: AppColors.destructive,
                      statusLabel: 'CANCELADO',
                      statusLabelColor: AppColors.destructive,
                      statusLabelBg: AppColors.destructive.withValues(alpha: 0.05),
                      date: 'octubre 21, 2025 13:51 p. m.',
                      items: '1 Elemento(s)',
                      total: '\$25.000',
                      icon: Icons.shopping_bag_outlined,
                      iconBg: AppColors.secondary,
                    ),
                    _buildOrderCard(
                      orderId: '#545',
                      status: 'Entregado',
                      statusColor: AppColors.success,
                      statusLabel: 'KOT',
                      statusLabelColor: AppColors.warning,
                      statusLabelBg: AppColors.warningBg,
                      date: 'octubre 21, 2025 13:51 p. m.',
                      items: '1 KOT',
                      total: '\$25.000',
                      icon: Icons.delivery_dining,
                      iconBg: AppColors.secondary,
                      hasAction: true,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderCard({
    required String orderId,
    required String status,
    required Color statusColor,
    required String statusLabel,
    required Color statusLabelColor,
    Color? statusLabelBg,
    required String date,
    required String items,
    required String total,
    required IconData icon,
    required Color iconBg,
    bool hasAction = false,
  }) {
    return Container(
      width: 400,
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(AppRadius.button),
                ),
                child: Icon(icon, color: AppColors.mutedForeground),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'jose',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: AppColors.foreground,
                      ),
                    ),
                    Text(
                      'Pedido $orderId',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: AppColors.foreground,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: statusLabelBg ?? AppColors.card,
                      border: statusLabelBg == null
                          ? Border.all(color: statusLabelColor)
                          : null,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        color: statusLabelColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        status,
                        style: const TextStyle(
                          color: AppColors.mutedForeground,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                date,
                style: const TextStyle(color: AppColors.mutedForeground, fontSize: 13),
              ),
              Text(items, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.foreground)),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Divider(color: AppColors.border),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                total,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.foreground,
                ),
              ),
              if (hasAction)
                OutlinedButton(
                  onPressed: () {},
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.foreground,
                    side: const BorderSide(color: AppColors.border),
                  ),
                  child: const Text('Nuevo KOT'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
