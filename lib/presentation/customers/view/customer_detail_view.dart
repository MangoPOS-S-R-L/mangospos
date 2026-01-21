import 'package:flutter/material.dart';

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
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          'Pedidos',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
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
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(width: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '$ordersCount PEDIDOS',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const Spacer(),
                const Text(
                  'Total: \$75.000',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),

            // Orders Grid
            LayoutBuilder(
              builder: (context, constraints) {
                return Wrap(
                  spacing: 24,
                  runSpacing: 24,
                  children: [
                    _buildOrderCard(
                      orderId: '#545',
                      status: 'Entregado',
                      statusColor: const Color(0xFF10B981), // Green
                      statusLabel: 'VERIFICACIÓN DE PAGO',
                      statusLabelColor: const Color(0xFFF97316), // Orange
                      date: 'octubre 21, 2025 13:51 p. m.',
                      items: '1 Elemento(s)',
                      total: '\$25.000',
                      icon: Icons.shopping_bag_outlined,
                      iconBg: const Color(0xFFF3F4F6),
                    ),
                    _buildOrderCard(
                      orderId: '#545',
                      status: 'Pedido Cancelado',
                      statusColor: const Color(0xFFEF4444), // Red
                      statusLabel: 'CANCELADO',
                      statusLabelColor: const Color(0xFFEF4444), // Red
                      statusLabelBg: const Color(0xFFFEF2F2),
                      date: 'octubre 21, 2025 13:51 p. m.',
                      items: '1 Elemento(s)',
                      total: '\$25.000',
                      icon: Icons.shopping_bag_outlined,
                      iconBg: const Color(0xFFF3F4F6),
                    ),
                    _buildOrderCard(
                      orderId: '#545',
                      status: 'Entregado',
                      statusColor: const Color(0xFF10B981), // Green
                      statusLabel: 'KOT',
                      statusLabelColor: const Color(0xFFD97706), // Amber
                      statusLabelBg: const Color(0xFFFEF3C7),
                      date: 'octubre 21, 2025 13:51 p. m.',
                      items: '1 KOT',
                      total: '\$25.000',
                      icon: Icons.delivery_dining,
                      iconBg: const Color(0xFFF3F4F6),
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
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
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
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: Colors.grey.shade400),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'jose',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      'Pedido $orderId',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.black87,
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
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: statusLabelBg ?? Colors.white,
                      border: statusLabelBg == null
                          ? Border.all(color: statusLabelColor)
                          : null,
                      borderRadius: BorderRadius.circular(4),
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
                  const SizedBox(height: 4),
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
                      const SizedBox(width: 4),
                      Text(
                        status,
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                date,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
              ),
              Text(items, style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16.0),
            child: Divider(),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                total,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              if (hasAction)
                OutlinedButton(
                  onPressed: () {},
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.black87,
                    side: BorderSide(color: Colors.grey.shade300),
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
