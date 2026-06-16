import 'package:flutter/material.dart';

import 'package:mangopos/data/models/kitchen_models.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_shadows.dart';

import 'kitchen_timer.dart';

String _formatQty(double qty) {
  if ((qty - qty.roundToDouble()).abs() < 0.001) {
    return qty.toStringAsFixed(0);
  }
  if ((qty * 10 - (qty * 10).roundToDouble()).abs() < 0.001) {
    return qty.toStringAsFixed(1);
  }
  return qty.toStringAsFixed(2);
}

bool _isDone(KitchenItem item) => item.status == 'ready';

/// 🧾 Comanda del tablero de cocina (tema claro, colores MangoPOS).
///
/// Modelo de interacción:
/// - Tap a un ítem pendiente lo marca como listo ([onBumpItem]) — queda
///   tachado pero la card NO desaparece.
/// - La card solo sale del tablero con "Marcar todo listo" ([onCompleteOrder]),
///   que marca lo que falte, imprime el ticket LISTO y despacha la orden.
///
/// La card crece según su contenido (sin recortes ni scroll interno).
class KitchenTicketCard extends StatelessWidget {
  final KitchenOrder order;

  /// Marca un solo ítem como listo (sin imprimir, sin despachar la orden).
  final void Function(String itemId) onBumpItem;

  /// Despacha la orden completa: marca lo que falte como listo, imprime el
  /// ticket LISTO y la saca del tablero.
  final void Function(String orderId) onCompleteOrder;

  const KitchenTicketCard({
    super.key,
    required this.order,
    required this.onBumpItem,
    required this.onCompleteOrder,
  });

  @override
  Widget build(BuildContext context) {
    final urgency = kitchenUrgencyFor(order.elapsedTime);
    final accent = kitchenUrgencyColor(urgency);

    final items = order.items;
    final doneCount = items.where(_isDone).length;
    final total = items.length;
    final allTakeout = items.isNotEmpty && items.every((i) => i.isTakeout);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: urgency == KitchenUrgency.normal
              ? AppColors.border
              : accent.withValues(alpha: 0.55),
          width: urgency == KitchenUrgency.urgent ? 1.5 : 1,
        ),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Barra de acento de urgencia.
          Container(height: 5, color: accent),

          // Encabezado.
          _Header(order: order, allTakeout: allTakeout),

          Divider(height: 1, thickness: 1, color: AppColors.border),

          // Lista de ítems — al marcar uno como listo queda tachado al fondo,
          // visible, hasta que se complete la orden. Crece con el contenido.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              children: [
                for (final item in items)
                  _ItemRow(
                    item: item,
                    showTakeoutBadge: !allTakeout && item.isTakeout,
                    onTap: _isDone(item) ? null : () => onBumpItem(item.id),
                  ),
              ],
            ),
          ),

          // Pie: progreso + acción primaria.
          _Footer(
            doneCount: doneCount,
            total: total,
            onComplete: () => onCompleteOrder(order.orderId),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final KitchenOrder order;
  final bool allTakeout;

  const _Header({required this.order, required this.allTakeout});

  @override
  Widget build(BuildContext context) {
    final table = order.tableName?.trim();
    final title = allTakeout
        ? 'Para llevar'
        : (table == null || table.isEmpty ? 'Mostrador' : table);

    final subParts = <String>[
      if (order.orderNumber.trim().isNotEmpty)
        'Orden ${order.orderNumber.trim()}',
      if ((order.waiterName ?? '').trim().isNotEmpty) order.waiterName!.trim(),
      '${order.items.length} ${order.items.length == 1 ? 'ítem' : 'ítems'}',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: AppColors.foreground,
                        ),
                      ),
                    ),
                    if (allTakeout) ...[
                      const SizedBox(width: 8),
                      const _TakeoutBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  subParts.join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          KitchenTimer(startTime: order.createdAt),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  final KitchenItem item;
  final bool showTakeoutBadge;
  final VoidCallback? onTap;

  const _ItemRow({
    required this.item,
    required this.showTakeoutBadge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final done = _isDone(item);
    final hasNotes = item.notes != null && item.notes!.trim().isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: done ? AppColors.muted.withValues(alpha: 0.5) : null,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Cantidad.
              Container(
                margin: const EdgeInsets.only(top: 1),
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: done
                      ? AppColors.muted
                      : AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  _formatQty(item.quantity),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: done ? AppColors.mutedForeground : AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Nombre + modificadores + notas.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            item.productName,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              height: 1.15,
                              color: done
                                  ? AppColors.mutedForeground
                                  : AppColors.foreground,
                              decoration: done
                                  ? TextDecoration.lineThrough
                                  : null,
                              decorationColor: AppColors.mutedForeground,
                            ),
                          ),
                        ),
                        if (showTakeoutBadge) ...[
                          const SizedBox(width: 6),
                          const _TakeoutBadge(),
                        ],
                      ],
                    ),
                    if (item.modifiers.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          item.modifiers.map((m) => m.name).join(', '),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.2,
                            color: AppColors.mutedForeground,
                            decoration:
                                done ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                    if (hasNotes)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.warning.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.sticky_note_2_outlined,
                                size: 13,
                                color: AppColors.warning,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  item.notes!.trim(),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    height: 1.2,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF92590B),
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
              const SizedBox(width: 8),
              // Toggle de listo.
              _CheckToggle(done: done, interactive: onTap != null),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckToggle extends StatelessWidget {
  final bool done;
  final bool interactive;

  const _CheckToggle({required this.done, required this.interactive});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 1),
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: done ? AppColors.success : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: done
              ? AppColors.success
              : (interactive
                  ? AppColors.primary.withValues(alpha: 0.55)
                  : AppColors.border),
          width: 2,
        ),
      ),
      child: done
          ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
          : null,
    );
  }
}

class _Footer extends StatelessWidget {
  final int doneCount;
  final int total;
  final VoidCallback onComplete;

  const _Footer({
    required this.doneCount,
    required this.total,
    required this.onComplete,
  });

  @override
  Widget build(BuildContext context) {
    final progress = total == 0 ? 0.0 : doneCount / total;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    backgroundColor: AppColors.muted,
                    valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$doneCount/$total',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Acción primaria — color sólido de marca MangoPOS.
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: onComplete,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
              icon: const Icon(Icons.done_all_rounded, size: 20),
              label: const Text(
                'Marcar todo listo',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TakeoutBadge extends StatelessWidget {
  const _TakeoutBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shopping_bag_outlined, size: 11, color: AppColors.info),
          const SizedBox(width: 3),
          Text(
            'Para llevar',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppColors.info,
            ),
          ),
        ],
      ),
    );
  }
}
