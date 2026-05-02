import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/presentation/kitchen/viewmodel/kitchen_viewmodel.dart';
import 'package:mangopos/data/models/kitchen_models.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/app/theme/mango_tokens.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_shadows.dart';

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
      backgroundColor: AppColors.background,
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
              readyItems: ready,
            ),
            const SizedBox(height: 18),
            Expanded(
              child: vm.isLoading
                  ? Center(child: CircularProgressIndicator(color: AppColors.primary))
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _buildOrderColumn(
                            title: 'En Espera',
                            color: AppColors.warning,
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
                            color: AppColors.info,
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
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Cocina (KDS)',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Sistema de visualizacion de comandas',
              style: TextStyle(color: AppColors.mutedForeground, fontSize: 13),
            ),
          ],
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
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
                activeThumbColor: AppColors.primary,
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
            foregroundColor: AppColors.foreground,
            side: BorderSide(color: AppColors.border),
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
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Icon(icon, color: AppColors.mutedForeground),
    );
  }

  Widget _buildStatsRow({
    required int pendingCount,
    required int preparingCount,
    required int completedToday,
    required List<KitchenItem> readyItems,
  }) {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            color: AppColors.warning,
            icon: Icons.timer_outlined,
            title: pendingCount.toString(),
            subtitle: 'En Espera',
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildStatCard(
            color: AppColors.info,
            icon: Icons.schedule,
            title: preparingCount.toString(),
            subtitle: 'En Preparacion',
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildStatCard(
            color: AppColors.success,
            icon: Icons.check_circle_outline,
            title: completedToday.toString(),
            subtitle: 'Completados Hoy',
            onTap: () => _showCompletedTodayDialog(context, readyItems),
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
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.card),
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
                style: TextStyle(color: AppColors.mutedForeground, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    ));
  }

  void _showCompletedTodayDialog(BuildContext context, List<KitchenItem> ready) {
    final now = DateTime.now();
    final completedTodayItems = ready.where((i) {
      final d = i.readyAt ?? i.createdAt;
      return d.year == now.year && d.month == now.month && d.day == now.day;
    }).toList(growable: false);

    final orders = _groupOrdersFromItems(completedTodayItems);

    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 700),
          child: Padding(
            padding: const EdgeInsets.all(24),
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
                        color: MangoTokens.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(
                        Icons.checklist_rounded,
                        color: MangoTokens.primary,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Completados hoy', style: MangoTokens.h1()),
                          const SizedBox(height: 6),
                          Text(
                            '${orders.length} comandas completadas en el día.',
                            style: MangoTokens.subtitle(),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: orders.isEmpty
                      ? Center(
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: MangoTokens.border),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.inbox_outlined,
                                  size: 28,
                                  color: MangoTokens.mutedForeground,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'No hay comandas completadas hoy.',
                                  style: MangoTokens.body(
                                    color: MangoTokens.mutedForeground,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: orders.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final order = orders[index];
                            final completedAt = order.items
                                .map((e) => e.readyAt ?? e.createdAt)
                                .reduce((a, b) => a.isAfter(b) ? a : b);
                            return Container(
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: MangoTokens.border),
                                boxShadow: MangoTokens.shadowCard,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: MangoTokens.secondary,
                                          borderRadius: BorderRadius.circular(14),
                                        ),
                                        child: const Icon(
                                          Icons.receipt_long_outlined,
                                          color: MangoTokens.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Orden ${order.orderNumber.isNotEmpty ? order.orderNumber : order.orderId.substring(0, 8).toUpperCase()}',
                                              style: MangoTokens.body().copyWith(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 16,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Mesa: ${order.tableName ?? 'N/A'} · Mesero: ${order.waiterName ?? 'N/A'}',
                                              style: MangoTokens.label(),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: MangoTokens.secondary,
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          '${completedAt.hour.toString().padLeft(2, '0')}:${completedAt.minute.toString().padLeft(2, '0')}',
                                          style: MangoTokens.label(
                                            color: MangoTokens.foreground,
                                          ).copyWith(fontWeight: FontWeight.w700),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: MangoTokens.secondary,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Items completados',
                                          style: MangoTokens.label(
                                            color: MangoTokens.foreground,
                                          ).copyWith(fontWeight: FontWeight.w700),
                                        ),
                                        const SizedBox(height: 10),
                                        ...order.items.map(
                                          (item) => Padding(
                                            padding: const EdgeInsets.only(bottom: 8),
                                            child: Row(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '${_formatQty(item.quantity)}x',
                                                  style: MangoTokens.body().copyWith(
                                                    fontWeight: FontWeight.w800,
                                                    color: MangoTokens.primary,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Text(
                                                    item.productName,
                                                    style: MangoTokens.body().copyWith(
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: MangoTokens.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Cerrar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<KitchenOrder> _groupOrdersFromItems(List<KitchenItem> items) {
    final map = <String, List<KitchenItem>>{};
    for (final item in items) {
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
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppRadius.full),
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
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.inbox_outlined, size: 32, color: AppColors.mutedForeground),
                      const SizedBox(height: 8),
                      Text(
                        'No hay pedidos',
                        style: TextStyle(color: AppColors.mutedForeground, fontSize: 13),
                      ),
                    ],
                  ),
                )
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
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: color, width: 4),
                bottom: BorderSide(color: AppColors.border),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.card),
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
                      borderRadius: BorderRadius.circular(AppRadius.md),
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
                          color: AppColors.muted,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
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
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    item.productName,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                if (item.isTakeout) ...[
                                  const SizedBox(width: 8),
                                  _TakeoutBadge(),
                                ],
                              ],
                            ),
                            if (item.notes != null && item.notes!.isNotEmpty)
                              Text(
                                item.notes!,
                                style: TextStyle(
                                  color: AppColors.destructive,
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

class _TakeoutBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: MangoColors.infoBlue.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(
          color: MangoColors.infoBlue.withValues(alpha: 0.4),
        ),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.shopping_bag_outlined,
            size: 11,
            color: MangoColors.infoBlue,
          ),
          SizedBox(width: 3),
          Text(
            'Para llevar',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: MangoColors.infoBlue,
            ),
          ),
        ],
      ),
    );
  }
}
