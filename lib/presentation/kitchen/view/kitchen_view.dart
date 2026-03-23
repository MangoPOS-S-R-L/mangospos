import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/presentation/kitchen/viewmodel/kitchen_viewmodel.dart';
import 'package:mangopos/data/models/kitchen_models.dart';
import 'package:mangopos/services/session/session_controller.dart';

String _formatQty(double qty) {
  if ((qty - qty.roundToDouble()).abs() < 0.001) {
    return qty.toStringAsFixed(0);
  }
  if ((qty * 10 - (qty * 10).roundToDouble()).abs() < 0.001) {
    return qty.toStringAsFixed(1);
  }
  return qty.toStringAsFixed(2);
}

class KitchenView extends ConsumerStatefulWidget {
  const KitchenView({super.key});

  @override
  ConsumerState<KitchenView> createState() => _KitchenViewState();
}

class _KitchenViewState extends ConsumerState<KitchenView> {
  bool autoUpdate = true;
  String? _lastBusinessId;
  String updateInterval = '10 Segundo';
  String filterType = 'Todos';
  String dateFilter = 'Hoy';
  String orderFilter = 'Mostrar Todo Pedidos';
  String waiterFilter = 'Mostrar Todo Mesero';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(kitchenViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final vm = ref.watch(kitchenViewModelProvider);
    final pending = vm.pendingItems;

    if (session.activeBusinessId != null &&
        session.activeBusinessId != _lastBusinessId) {
      _lastBusinessId = session.activeBusinessId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(kitchenViewModelProvider).init();
        }
      });
    }
    final preparing = vm.preparingItems;
    final ready = vm.readyItems;
    final pendingOrders = _groupOrdersByStatus(vm.items, 'pending');
    final preparingOrders = _groupOrdersByStatus(vm.items, 'preparing');
    final completedToday = ready.where((i) {
      final d = i.readyAt ?? i.createdAt;
      final now = DateTime.now();
      return d.year == now.year && d.month == now.month && d.day == now.day;
    }).length;

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            const SizedBox(height: 20),
            _buildStatsRow(
              pendingCount: pending.length,
              preparingCount: preparing.length,
              completedToday: completedToday,
            ),
            const SizedBox(height: 18),
            Expanded(
              child: vm.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _buildOrderColumn(
                            title: 'En Espera',
                            color: const Color(0xFFF59E0B),
                            orders: pendingOrders,
                            actionLabel: 'Preparar',
                            onAction: (orderId) => ref
                                .read(kitchenViewModelProvider)
                                .startPreparingOrder(orderId),
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: _buildOrderColumn(
                            title: 'En Preparacion',
                            color: const Color(0xFF3B82F6),
                            orders: preparingOrders,
                            actionLabel: 'Listo',
                            onAction: (orderId) => ref
                                .read(kitchenViewModelProvider)
                                .markOrderReady(orderId),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.restaurant_menu, color: Color(0xFFF26900), size: 28),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Cocina (KDS)',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF111827),
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Sistema de visualizacion de comandas',
              style: TextStyle(color: Color(0xFF6B7280), fontSize: 13),
            ),
          ],
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            children: [
              const Text(
                'Auto-refresh',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 10),
              Switch(
                value: autoUpdate,
                onChanged: (val) => setState(() => autoUpdate = val),
                activeThumbColor: const Color(0xFFF26900),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: () => ref.read(kitchenViewModelProvider).refresh(),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Actualizar'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            foregroundColor: const Color(0xFF111827),
            side: BorderSide(color: Colors.grey.shade300),
          ),
        ),
        const SizedBox(width: 8),
        _iconButton(Icons.keyboard_arrow_up),
        const SizedBox(width: 6),
        _iconButton(Icons.keyboard_arrow_down),
      ],
    );
  }

  Widget _iconButton(IconData icon) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Icon(icon, color: const Color(0xFF6B7280)),
    );
  }

  Widget _buildStatsRow({
    required int pendingCount,
    required int preparingCount,
    required int completedToday,
  }) {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            color: const Color(0xFFF59E0B),
            icon: Icons.timer_outlined,
            title: pendingCount.toString(),
            subtitle: 'En Espera',
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildStatCard(
            color: const Color(0xFF3B82F6),
            icon: Icons.schedule,
            title: preparingCount.toString(),
            subtitle: 'En Preparacion',
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildStatCard(
            color: const Color(0xFF22C55E),
            icon: Icons.check_circle_outline,
            title: completedToday.toString(),
            subtitle: 'Completados Hoy',
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required Color color,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<KitchenOrder> _groupOrdersByStatus(
    List<KitchenItem> items,
    String status,
  ) {
    final filtered = items.where((i) => i.status == status);
    final map = <String, List<KitchenItem>>{};
    for (final item in filtered) {
      map.putIfAbsent(item.orderId, () => []).add(item);
    }
    return map.entries.map((entry) {
      final list = entry.value;
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final first = list.first;
      return KitchenOrder(
        orderId: entry.key,
        orderNumber: first.orderNumber,
        tableName: first.tableName,
        waiterName: first.waiterName,
        createdAt: first.createdAt,
        items: list,
      );
    }).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  Widget _buildOrderColumn({
    required String title,
    required Color color,
    required List<KitchenOrder> orders,
    required String actionLabel,
    required void Function(String orderId) onAction,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                orders.length.toString(),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: color,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: orders.isEmpty
              ? const Center(child: Text('No hay pedidos'))
              : ListView.separated(
                  itemCount: orders.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 16),
                  itemBuilder: (_, i) => _buildOrderCard(
                    orders[i],
                    color: color,
                    actionLabel: actionLabel,
                    onAction: onAction,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildOrderCard(
    KitchenOrder order, {
    required Color color,
    required String actionLabel,
    required void Function(String orderId) onAction,
  }) {
    final diff = DateTime.now().difference(order.createdAt).inMinutes;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: color, width: 4),
                bottom: BorderSide(color: Colors.grey.shade200),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    (order.tableName ?? 'Mesa').replaceAll('Mesa ', ''),
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        order.orderNumber.isEmpty ? 'ORD' : order.orderNumber,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.access_time, size: 14, color: color),
                          const SizedBox(width: 6),
                          Text(
                            '$diff min',
                            style: TextStyle(color: color, fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  onPressed: () => onAction(order.orderId),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: color,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(actionLabel),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: order.items.map((item) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3F4F6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _formatQty(item.quantity),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.productName,
                              style: const TextStyle(fontSize: 13),
                            ),
                            if (item.notes != null && item.notes!.isNotEmpty)
                              Text(
                                item.notes!,
                                style: TextStyle(
                                  color: Colors.red[400],
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
