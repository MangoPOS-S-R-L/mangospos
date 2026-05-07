import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/breakpoints.dart';
import '../../../data/models/kitchen_models.dart';
import '../viewmodel/kds_viewmodel.dart';
import '../widgets/order_card.dart';
import '../widgets/kds_stats_bar.dart';

/// 🍳 Pantalla principal del KDS
class KitchenDisplayScreen extends ConsumerStatefulWidget {
  final String? areaCode;

  const KitchenDisplayScreen({super.key, this.areaCode});

  @override
  ConsumerState<KitchenDisplayScreen> createState() =>
      _KitchenDisplayScreenState();
}

class _KitchenDisplayScreenState extends ConsumerState<KitchenDisplayScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(kdsViewModelProvider.notifier)
          .initialize(areaCode: widget.areaCode);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final vm = ref.read(kdsViewModelProvider.notifier);
    if (state == AppLifecycleState.paused) {
      vm.pauseRefresh();
    } else if (state == AppLifecycleState.resumed) {
      vm.resumeRefresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(kdsViewModelProvider);
    final viewModel = ref.read(kdsViewModelProvider.notifier);

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Row(
          children: [
            const Icon(Icons.restaurant_menu, color: Color(0xFFF97316)),
            const SizedBox(width: 12),
            const Text(
              'Kitchen Display System',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const Spacer(),
            // Stats
            if (state.stats.isNotEmpty) ...[
              _StatChip(
                label: 'Pendientes',
                value: state.stats['pending'] ?? 0,
                color: Colors.red,
              ),
              const SizedBox(width: 8),
              _StatChip(
                label: 'Preparando',
                value: state.stats['preparing'] ?? 0,
                color: const Color(0xFFF97316),
              ),
              const SizedBox(width: 8),
              _StatChip(
                label: 'Listos',
                value: state.stats['ready'] ?? 0,
                color: const Color(0xFF22C55E),
              ),
            ],
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFFF97316),
          labelColor: const Color(0xFFF97316),
          unselectedLabelColor: Colors.grey[400],
          tabs: [
            Tab(
              icon: const Icon(Icons.pending_actions),
              text: 'Pendientes (${state.pendingOrders.length})',
            ),
            Tab(
              icon: const Icon(Icons.restaurant),
              text: 'Preparando (${state.preparingOrders.length})',
            ),
            Tab(
              icon: const Icon(Icons.check_circle),
              text: 'Listos (${state.readyOrders.length})',
            ),
          ],
        ),
        actions: [
          // Sound toggle
          IconButton(
            icon: Icon(
              state.soundEnabled ? Icons.volume_up : Icons.volume_off,
              color: Colors.white,
            ),
            onPressed: () => viewModel.toggleSound(),
          ),
          // Auto-refresh toggle
          IconButton(
            icon: Icon(
              state.autoRefresh ? Icons.sync : Icons.sync_disabled,
              color: state.autoRefresh ? const Color(0xFF22C55E) : Colors.grey,
            ),
            onPressed: () => viewModel.toggleAutoRefresh(),
          ),
          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () => viewModel.loadOrders(),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: state.loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFF97316)))
          : Column(
              children: [
                // Stats bar
                if (state.averageTime != null)
                  KdsStatsBar(averageTime: state.averageTime!),

                // Error message
                if (state.error != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.red[900],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error, color: Colors.white),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            state.error!,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Content
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildOrdersGrid(state.pendingOrders, viewModel),
                      _buildOrdersGrid(state.preparingOrders, viewModel),
                      _buildOrdersGrid(state.readyOrders, viewModel),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// Particiona orders por isTakeout: si una orden tiene MIX, emite 2
  /// entradas (regular + PARA LLEVAR). Si todos los items son del mismo
  /// tipo, emite una sola entrada con el flag correspondiente.
  ///
  /// Mantener orderId/orderNumber/timer compartidos en ambas entradas:
  /// son la misma orden visual pero el chef las maneja como buckets
  /// separados — cuando da "Marcar Todo Listo" en un card, solo afecta
  /// los items del bucket gracias al filtrado del lado del callback.
  List<({KitchenOrder order, bool isTakeoutBucket})> _splitOrdersByTakeout(
    List<KitchenOrder> orders,
  ) {
    final out = <({KitchenOrder order, bool isTakeoutBucket})>[];
    for (final o in orders) {
      final regular = o.items.where((i) => !i.isTakeout).toList();
      final takeout = o.items.where((i) => i.isTakeout).toList();
      if (takeout.isEmpty) {
        out.add((order: o, isTakeoutBucket: false));
        continue;
      }
      if (regular.isEmpty) {
        out.add((order: o, isTakeoutBucket: true));
        continue;
      }
      // Mix: emitir 2 cards. Mismo header, items filtrados.
      out.add((
        order: KitchenOrder(
          orderId: o.orderId,
          orderNumber: o.orderNumber,
          tableName: o.tableName,
          waiterName: o.waiterName,
          createdAt: o.createdAt,
          items: regular,
        ),
        isTakeoutBucket: false,
      ));
      out.add((
        order: KitchenOrder(
          orderId: o.orderId,
          orderNumber: o.orderNumber,
          tableName: o.tableName,
          waiterName: o.waiterName,
          createdAt: o.createdAt,
          items: takeout,
        ),
        isTakeoutBucket: true,
      ));
    }
    return out;
  }

  Widget _buildOrdersGrid(orders, viewModel) {
    if (orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 64, color: Colors.grey[700]),
            const SizedBox(height: 16),
            Text(
              'No hay órdenes en esta sección',
              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    // PRD 6 § 4.3 — en compact (<1366) las cards se hacen más estrechas
    // (340 max) para caber 3 columnas cómodas en 1280-1366 px sin
    // comprimir contenido. En regular/wide mantenemos 400 (4 cols+).
    final maxCardWidth = Breakpoints.isCompact(context) ? 340.0 : 400.0;
    final buckets = _splitOrdersByTakeout(
      orders is List<KitchenOrder> ? orders : List<KitchenOrder>.from(orders),
    );
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxCardWidth,
        childAspectRatio: 0.8,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: buckets.length,
      itemBuilder: (context, index) {
        final bucket = buckets[index];
        final order = bucket.order;
        return OrderCard(
          order: order,
          isTakeoutBucket: bucket.isTakeoutBucket,
          onItemStatusChange: (itemId, status) async {
            switch (status) {
              case 'preparing':
                await viewModel.startPreparingItem(itemId);
                break;
              case 'ready':
                await viewModel.markItemReady(itemId);
                break;
              case 'served':
                await viewModel.markItemServed(itemId);
                break;
            }
          },
          // En lugar de markOrderReady (que afectaria toda la orden,
          // incluyendo el OTRO bucket), iteramos solo los items de
          // este bucket. Asi "Marcar Todo Listo" en el card "PARA LLEVAR"
          // no marca los items in-house y viceversa.
          onMarkAllReady: () async {
            for (final item in order.items) {
              if (!item.isReady && !item.isServed) {
                await viewModel.markItemReady(item.id);
              }
            }
          },
        );
      },
    );
  }
}

// ============================================================
// WIDGETS AUXILIARES
// ============================================================

class _StatChip extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              value.toString(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
