import 'package:flutter/material.dart';

import '../../../data/models/kitchen_models.dart';
import 'timer_widget.dart';

/// 📦 Card de orden para KDS
class OrderCard extends StatelessWidget {
  final KitchenOrder order;
  final Function(String itemId, String status) onItemStatusChange;
  final VoidCallback onMarkAllReady;

  const OrderCard({
    super.key,
    required this.order,
    required this.onItemStatusChange,
    required this.onMarkAllReady,
  });

  @override
  Widget build(BuildContext context) {
    final isUrgent = order.elapsedTime.inMinutes > 15;
    final isWarning = order.elapsedTime.inMinutes > 10;

    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isUrgent
              ? Colors.red
              : isWarning
              ? const Color(0xFFF97316)
              : Colors.grey[700]!,
          width: isUrgent ? 3 : 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isUrgent
                  ? Colors.red[900]
                  : isWarning
                  ? const Color(0xFFF97316)
                  : Colors.grey[800],
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Order number
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF97316),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        order.orderNumber,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    // Timer
                    TimerWidget(startTime: order.createdAt),
                  ],
                ),
                const SizedBox(height: 8),
                // Table and waiter
                Row(
                  children: [
                    Icon(
                      Icons.table_restaurant,
                      size: 16,
                      color: Colors.grey[400],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      order.tableName ?? 'N/A',
                      style: TextStyle(color: Colors.grey[300], fontSize: 14),
                    ),
                    if (order.waiterName != null) ...[
                      const SizedBox(width: 16),
                      Icon(Icons.person, size: 16, color: Colors.grey[400]),
                      const SizedBox(width: 4),
                      Text(
                        order.waiterName!,
                        style: TextStyle(color: Colors.grey[300], fontSize: 14),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // Items list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: order.items.length,
              itemBuilder: (context, index) {
                final item = order.items[index];
                return _ItemCard(
                  item: item,
                  onStatusChange: (status) =>
                      onItemStatusChange(item.id, status),
                );
              },
            ),
          ),

          // Footer actions
          if (!order.allReady)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[800],
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onMarkAllReady,
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Marcar Todo Listo'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF22C55E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================
// ITEM CARD
// ============================================================

class _ItemCard extends StatelessWidget {
  final KitchenItem item;
  final Function(String status) onStatusChange;

  const _ItemCard({required this.item, required this.onStatusChange});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _getBackgroundColor(),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _getBorderColor()),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Quantity and name
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF97316),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'x${item.quantity.toInt()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.productName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _StatusBadge(status: item.status),
            ],
          ),

          // Modifiers
          if (item.modifiers.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...item.modifiers.map(
              (mod) => Padding(
                padding: const EdgeInsets.only(left: 16, top: 4),
                child: Row(
                  children: [
                    Icon(
                      mod.name.contains(': ')
                          ? Icons.radio_button_checked
                          : Icons.add,
                      size: 12,
                      color: mod.name.contains(': ')
                          ? const Color(0xFFFB923C)
                          : Colors.grey[400],
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        mod.name,
                        style: TextStyle(
                          color: mod.name.contains(': ')
                              ? const Color(0xFFFED7AA)
                              : Colors.grey[400],
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // Notes
          if (item.notes != null && item.notes!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.yellow[900]?.withOpacity(0.3),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.yellow[700]!),
              ),
              child: Row(
                children: [
                  Icon(Icons.note, size: 14, color: Colors.yellow[700]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.notes!,
                      style: TextStyle(
                        color: Colors.yellow[100],
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Action buttons
          const SizedBox(height: 12),
          Row(
            children: [
              if (item.isPending)
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => onStatusChange('preparing'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF97316),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    child: const Text('Iniciar'),
                  ),
                ),
              if (item.isPreparing) ...[
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => onStatusChange('ready'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF22C55E),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    child: const Text('Listo'),
                  ),
                ),
              ],
              if (item.isReady)
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => onStatusChange('served'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    child: const Text('Servido'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Color _getBackgroundColor() {
    switch (item.status) {
      case 'pending':
        return Colors.red[900]!.withOpacity(0.2);
      case 'preparing':
        return const Color(0xFFF97316).withOpacity(0.2);
      case 'ready':
        return const Color(0xFF22C55E).withOpacity(0.2);
      default:
        return Colors.grey[800]!;
    }
  }

  Color _getBorderColor() {
    switch (item.status) {
      case 'pending':
        return Colors.red[700]!;
      case 'preparing':
        return const Color(0xFFF97316);
      case 'ready':
        return const Color(0xFF22C55E);
      default:
        return Colors.grey[700]!;
    }
  }
}

// ============================================================
// STATUS BADGE
// ============================================================

class _StatusBadge extends StatelessWidget {
  final String status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _getColor(),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _getLabel(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Color _getColor() {
    switch (status) {
      case 'pending':
        return Colors.red;
      case 'preparing':
        return const Color(0xFFF97316);
      case 'ready':
        return const Color(0xFF22C55E);
      case 'served':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  String _getLabel() {
    switch (status) {
      case 'pending':
        return 'PENDIENTE';
      case 'preparing':
        return 'PREPARANDO';
      case 'ready':
        return 'LISTO';
      case 'served':
        return 'SERVIDO';
      default:
        return status.toUpperCase();
    }
  }
}
