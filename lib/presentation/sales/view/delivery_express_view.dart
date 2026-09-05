import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_text_styles.dart';
import 'package:mangopos/presentation/sales/state/delivery_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/delivery_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/core/utils/app_snackbar.dart';

class DeliveryExpressView extends ConsumerStatefulWidget {
  const DeliveryExpressView({super.key});

  @override
  ConsumerState<DeliveryExpressView> createState() =>
      _DeliveryExpressViewState();
}

class _DeliveryExpressViewState extends ConsumerState<DeliveryExpressView> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      final bizId = ref.read(sessionProvider).activeBusinessId ?? 'auto';
      ref.read(deliveryVmProvider.notifier).load(bizId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(deliveryVmProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: const BoxDecoration(
              color: AppColors.card,
              border: Border(
                bottom: BorderSide(color: AppColors.border),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.local_shipping_outlined,
                  color: AppColors.primary,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Text(
                  'Delivery',
                  style: AppTextStyles.tableCode.copyWith(
                    color: AppColors.foreground,
                  ),
                ),
                const Spacer(),
                if (state.orders.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Text(
                      '${state.orders.length} orden${state.orders.length == 1 ? '' : 'es'}',
                      style: AppTextStyles.tableStatus.copyWith(
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ),
                _NewDeliveryButton(onCreated: _onOrderCreated),
              ],
            ),
          ),

          // Content
          Expanded(
            child: state.loading && state.orders.isEmpty
                ? const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.primary,
                    ),
                  )
                : state.error != null && state.orders.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Error cargando delivery',
                              style: AppTextStyles.tableCode.copyWith(
                                color: AppColors.foreground,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              state.error!,
                              style: AppTextStyles.tableMetrics.copyWith(
                                color: AppColors.mutedForeground,
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextButton.icon(
                              onPressed: () => ref
                                  .read(deliveryVmProvider.notifier)
                                  .refresh(),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Reintentar'),
                            ),
                          ],
                        ),
                      )
                    : state.orders.isEmpty
                        ? _EmptyDelivery(onCreated: _onOrderCreated)
                        : _DeliveryGrid(
                            orders: state.orders,
                            onTap: _onOrderTap,
                          ),
          ),
        ],
      ),
    );
  }

  void _onOrderCreated(Map<String, dynamic> result) {
    final tableId = result['table_id'] as String?;
    final deliveryType = result['delivery_type'] as String? ?? 'own';
    if (tableId == null) return;

    ref.read(currentOrderProvider.notifier).openDeliveryOrder(
          tableId: tableId,
          deliveryType: deliveryType,
        );

    context.go(
      Uri(
        path: AppRoutes.salesReact,
        queryParameters: {
          'mode': 'delivery_order',
          'tableId': tableId,
          'deliveryType': deliveryType,
        },
      ).toString(),
    );
  }

  void _onOrderTap(DeliveryOrderSummary order) {
    ref.read(currentOrderProvider.notifier).openDeliveryOrder(
          tableId: order.tableId,
          deliveryType: order.deliveryType,
        );

    context.go(
      Uri(
        path: AppRoutes.salesReact,
        queryParameters: {
          'mode': 'delivery_order',
          'tableId': order.tableId,
          'deliveryType': order.deliveryType,
        },
      ).toString(),
    );
  }
}

// ============================================================
// New Delivery Button (dropdown)
// ============================================================
class _NewDeliveryButton extends ConsumerWidget {
  final void Function(Map<String, dynamic> result) onCreated;
  const _NewDeliveryButton({required this.onCreated});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      onSelected: (type) async {
        try {
          final result =
              await ref.read(deliveryVmProvider.notifier).createOrder(type);
          onCreated(result);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showAppSnackBar(
              SnackBar(content: Text('Error creando delivery: $e')),
            );
          }
        }
      },
      offset: const Offset(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (_) => [
        _deliveryMenuItem('own', Icons.delivery_dining, AppColors.info,
            'Delivery Propio'),
        _deliveryMenuItem(
            'uber_eats', Icons.restaurant, const Color(0xFF06C167), 'Uber Eats'),
        _deliveryMenuItem(
            'pedidos_ya', Icons.fastfood, const Color(0xFFFF0050), 'Pedidos Ya'),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.add, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              'Nueva orden',
              style: AppTextStyles.tableTotal.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _deliveryMenuItem(
      String value, IconData icon, Color color, String label) {
    return PopupMenuItem(
      value: value,
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(label),
        dense: true,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }
}

// ============================================================
// Empty state
// ============================================================
class _EmptyDelivery extends StatelessWidget {
  final void Function(Map<String, dynamic> result) onCreated;
  const _EmptyDelivery({required this.onCreated});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_shipping_outlined,
            size: 64,
            color: AppColors.mutedForeground.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            'No hay ordenes de delivery activas',
            style: AppTextStyles.tableCode.copyWith(
              color: AppColors.mutedForeground,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Crea una nueva orden para comenzar',
            style: AppTextStyles.tableMetrics.copyWith(
              color: AppColors.mutedForeground,
            ),
          ),
          const SizedBox(height: 24),
          _NewDeliveryButton(onCreated: onCreated),
        ],
      ),
    );
  }
}

// ============================================================
// Delivery Grid (misma estructura que SalesByZoneView grid)
// ============================================================
class _DeliveryGrid extends StatelessWidget {
  final List<DeliveryOrderSummary> orders;
  final void Function(DeliveryOrderSummary) onTap;

  const _DeliveryGrid({required this.orders, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Wrap(
        spacing: 24,
        runSpacing: 24,
        children: orders
            .map((o) => _DeliveryOrderCard(order: o, onTap: () => onTap(o)))
            .toList(),
      ),
    );
  }
}

// ============================================================
// Delivery Order Card (estilo idéntico a TableCard)
// ============================================================
class _DeliveryOrderCard extends StatefulWidget {
  final DeliveryOrderSummary order;
  final VoidCallback onTap;

  const _DeliveryOrderCard({required this.order, required this.onTap});

  @override
  State<_DeliveryOrderCard> createState() => _DeliveryOrderCardState();
}

class _DeliveryOrderCardState extends State<_DeliveryOrderCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final elapsed = DateTime.now().difference(order.openedAt);
    final elapsedText = elapsed.inMinutes < 60
        ? '${elapsed.inMinutes} min'
        : '${elapsed.inHours}h ${elapsed.inMinutes % 60}m';

    final (Color borderColor, String statusLabel) = _statusStyle(order);
    final (Color typeColor, IconData typeIcon) = _typeStyle(order.deliveryType);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _isHovered ? 1.02 : 1.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            height: 140,
            width: 280,
            constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: _isHovered ? 0.08 : 0.05,
                  ),
                  blurRadius: _isHovered ? 12 : 3,
                  offset: _isHovered
                      ? const Offset(0, 4)
                      : const Offset(0, 1),
                ),
              ],
              border: Border(
                left: BorderSide(color: borderColor, width: 6),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // TOP: Código + Total
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: AppTextStyles.tableCode.copyWith(
                              color: _isHovered
                                  ? AppColors.primary
                                  : AppColors.foreground,
                            ),
                            child: Text(order.tableCode),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            statusLabel,
                            style: AppTextStyles.tableStatus.copyWith(
                              color: borderColor,
                            ),
                          ),
                        ],
                      ),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Consumer(
                              builder: (context, ref, _) {
                                final currency =
                                    currentBusinessCurrencyOrFallback(ref);
                                return Text(
                                  _formatCurrency(currency, order.total),
                                  style: AppTextStyles.tableTotal.copyWith(
                                    color: AppColors.foreground,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                );
                              },
                            ),
                            if (order.customerName?.trim().isNotEmpty ==
                                true) ...[
                              const SizedBox(height: 4),
                              Text(
                                order.customerName!.trim(),
                                style: AppTextStyles.tableWaiter.copyWith(
                                  color: AppColors.foreground,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.end,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),

                  // Divider
                  const SizedBox(height: 8),
                  Container(
                    height: 1,
                    width: double.infinity,
                    color: AppColors.borderDivider,
                  ),
                  const SizedBox(height: 8),

                  // Dirección de entrega (si está capturada)
                  if (order.deliveryAddress?.trim().isNotEmpty == true) ...[
                    Row(
                      children: [
                        const Icon(
                          Icons.location_on_outlined,
                          size: 13,
                          color: AppColors.mutedForeground,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            order.deliveryAddress!.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.tableMetrics.copyWith(
                              color: AppColors.mutedForeground,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],

                  // BOTTOM: Badge tipo + métricas
                  Row(
                    children: [
                      // Badge delivery type
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: typeColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(9999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(typeIcon, size: 12, color: typeColor),
                            const SizedBox(width: 4),
                            Text(
                              order.deliveryLabel,
                              style: AppTextStyles.tableBadge.copyWith(
                                color: typeColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Tiempo
                      Icon(
                        Icons.access_time,
                        size: 16,
                        color: AppColors.mutedForeground,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        elapsedText,
                        style: AppTextStyles.tableMetrics.copyWith(
                          color: AppColors.mutedForeground,
                        ),
                      ),
                      const Spacer(),
                      // Items count
                      Text(
                        '${order.itemsCount} prod.',
                        style: AppTextStyles.tableMetrics.copyWith(
                          color: AppColors.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  (Color, String) _statusStyle(DeliveryOrderSummary order) {
    if (order.status == 'paid') {
      return (AppColors.success, 'Pagado');
    }
    if (order.isPendingPayment) {
      return (AppColors.warning, 'Pendiente de pago');
    }
    if (order.status == 'sent' || order.status == 'sent_to_kitchen') {
      return (AppColors.info, 'En preparacion');
    }
    return (AppColors.warning, 'Ocupado');
  }

  (Color, IconData) _typeStyle(String type) {
    switch (type) {
      case 'uber_eats':
        return (const Color(0xFF06C167), Icons.restaurant);
      case 'pedidos_ya':
        return (const Color(0xFFFF0050), Icons.fastfood);
      default:
        return (AppColors.info, Icons.delivery_dining);
    }
  }

  String _formatCurrency(BusinessCurrency currency, double amount) {
    return '${currency.symbol} ${NumberFormat('#,##0', 'en_US').format(amount)}';
  }
}
