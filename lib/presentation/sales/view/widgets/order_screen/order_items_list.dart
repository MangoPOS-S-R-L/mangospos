import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';

// `cleanOrderItemNote` vive ahora en order_pricing_utils.dart (util pura,
// compartida con la UI y los tickets); se usa vía el import de esa util.

/// 🛒 Lista de items de la orden actual.
///
/// Renderiza items en estado `draft` (pendientes de enviar) y `pending/sent`
/// (ya enviados a cocina). Permite eliminar items en draft via callback.
///
/// Diseño visual inspirado en `_CartLineItem` de `table_order_screen.dart`
/// pero simplificado y desacoplado del provider para permitir reutilizar
/// en flujos Quick/Manual.
///
/// El widget NO modifica el state — sólo renderiza y emite callbacks.
/// La vista que lo embebe se encarga de invocar `addItem`/`deleteItem`/etc.
/// en `sales_viewmodel`.
class OrderItemsList extends StatelessWidget {
  final Order order;
  final List<OrderItem> items;

  /// Callback al tocar el botón de borrar (sólo aparece en items draft).
  /// Si es null, el botón de borrar no se renderiza.
  final void Function(OrderItem item)? onDeleteItem;

  /// Callback al tocar la línea (típicamente abre `product_detail_modal`
  /// para editar cantidad/notas/modificadores). Si es null, la línea
  /// no es interactiva.
  final void Function(OrderItem item)? onTapItem;

  /// Si el usuario actual no tiene permiso para borrar items, esto
  /// oculta los botones de borrar incluso para items draft.
  final bool canDeleteDrafts;

  /// Mensaje cuando la orden está vacía.
  final String emptyMessage;

  const OrderItemsList({
    super.key,
    required this.order,
    required this.items,
    this.onDeleteItem,
    this.onTapItem,
    this.canDeleteDrafts = true,
    this.emptyMessage = 'Sin productos. Agregá uno para empezar.',
  });

  @override
  Widget build(BuildContext context) {
    final activeItems = items
        .where((i) => i.status != 'void')
        .toList(growable: false);

    if (activeItems.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            emptyMessage,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF7A7A7A),
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final draftItems = activeItems.where((i) => i.status == 'draft').toList();
    final sentItems = activeItems.where((i) => i.status != 'draft').toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (draftItems.isNotEmpty) ...[
          const _SectionLabel('POR CONFIRMAR'),
          ...draftItems.map(
            (item) => _ItemRow(
              order: order,
              item: item,
              isDraft: true,
              onDelete: canDeleteDrafts && onDeleteItem != null
                  ? () => onDeleteItem!(item)
                  : null,
              onTap: onTapItem != null ? () => onTapItem!(item) : null,
            ),
          ),
        ],
        if (sentItems.isNotEmpty) ...[
          if (draftItems.isNotEmpty) const SizedBox(height: 16),
          const _SectionLabel('ENVIADOS A COCINA'),
          ...sentItems.map(
            (item) => _ItemRow(
              order: order,
              item: item,
              isDraft: false,
              onDelete: null,
              onTap: onTapItem != null ? () => onTapItem!(item) : null,
            ),
          ),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Color(0xFFF97316),
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  final Order order;
  final OrderItem item;
  final bool isDraft;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  const _ItemRow({
    required this.order,
    required this.item,
    required this.isDraft,
    required this.onDelete,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,##0.00', 'en_US');
    final qty = item.quantity == item.quantity.roundToDouble()
        ? item.quantity.toStringAsFixed(0)
        : item.quantity.toStringAsFixed(1);
    final lineTotal = itemDisplayTotal(order, item);

    return Tooltip(
      // Tooltip de auditoría: solo dispara con hover de mouse (~1s).
      // `triggerMode: manual` desactiva el long-press default — el long-press
      // en una caja registradora se confunde con intención de seleccionar
      // o arrastrar. Hover sigue funcionando porque Flutter lo maneja por
      // separado del triggerMode (MouseRegion siempre presente).
      waitDuration: const Duration(seconds: 1),
      triggerMode: TooltipTriggerMode.manual,
      richMessage: _buildAuditTooltipSpan(context),
      preferBelow: false,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2C).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12, height: 1.45),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: Colors.black.withValues(alpha: 0.04),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 36,
                child: onDelete != null
                    ? IconButton(
                        onPressed: onDelete,
                        icon: const Icon(
                          Icons.close,
                          color: Color(0xFFEF4444),
                          size: 18,
                        ),
                        splashRadius: 16,
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  qty,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2C2C2C),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (!isDraft)
                const Padding(
                  padding: EdgeInsets.only(right: 6, top: 2),
                  child: Icon(
                    Icons.check_circle,
                    size: 16,
                    color: Color(0xFF22C55E),
                  ),
                ),
              if (item.isTakeout) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 6, top: 1),
                  child: Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3E8),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.shopping_bag_outlined,
                      size: 13,
                      color: Color(0xFFF97316),
                    ),
                  ),
                ),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.productName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF2C2C2C),
                      ),
                    ),
                    if (item.modifiers.isNotEmpty)
                      ...item.modifiers.map(
                        (m) => Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '+ ${m.name}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF7A7A7A),
                            ),
                          ),
                        ),
                      ),
                    if (cleanOrderItemNote(item.notes).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          cleanOrderItemNote(item.notes),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                            color: Color(0xFF7A7A7A),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'RD\$ ${currency.format(lineTotal)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFF97316),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  /// Construye el rich message del Tooltip de auditoría:
  /// - Nombre del producto en bold
  /// - Fecha/hora exacta en que se agregó el item
  /// - Empleado/mozo que lo agregó (`null` si fue antes de multimesero
  ///   o el empleado fue borrado)
  /// - Notas del item, si las hay
  /// - Origen de la orden (dine_in, manual, etc.) + estado de impresión
  ///   ("IMPR. SI" si ya pasó de draft, "IMPR. NO" si todavía no se
  ///   envió a cocina)
  InlineSpan _buildAuditTooltipSpan(BuildContext context) {
    final dateFmt = DateFormat('dd-MM-yyyy HH:mm');
    final fechaHora = dateFmt.format(item.createdAt.toLocal());
    final mozo = item.createdByEmployeeName ?? 'Sin asignar';
    final notes = item.notes?.trim() ?? '';
    final origen = order.origin.isEmpty ? '—' : order.origin;
    final impreso = item.status == 'draft' ? 'NO' : 'SI';

    const labelStyle = TextStyle(color: Color(0xFFCBD5E1), fontSize: 12);
    const valueStyle = TextStyle(color: Colors.white, fontSize: 12);

    return TextSpan(
      style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.5),
      children: [
        TextSpan(
          text: '${item.productName}\n',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const TextSpan(text: 'Agregado: ', style: labelStyle),
        TextSpan(text: '$fechaHora\n', style: valueStyle),
        const TextSpan(text: 'Mozo: ', style: labelStyle),
        TextSpan(text: '$mozo\n', style: valueStyle),
        if (notes.isNotEmpty) ...[
          const TextSpan(text: 'Notas: ', style: labelStyle),
          TextSpan(text: '$notes\n', style: valueStyle),
        ],
        const TextSpan(text: 'Origen: ', style: labelStyle),
        TextSpan(text: '$origen · IMPR. $impreso', style: valueStyle),
      ],
    );
  }
}
