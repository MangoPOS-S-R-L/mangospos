import '../../data/models/order_item_tax_line.dart';
import '../../data/models/sales_models.dart';

/// Lossless item representation shared by disk snapshots and LAN operations.
class OrderItemSnapshot {
  static Map<String, dynamic> encode(OrderItem item) => {
    'snapshot_version': 1,
    'id': item.id,
    'order_id': item.orderId,
    'product_id': item.productId,
    'product_name': item.productName,
    'sku': item.sku,
    'qty': item.quantity,
    'quantity': item.quantity,
    'unit_price': item.unitPrice,
    'subtotal': item.subtotal,
    'discounts': item.discounts,
    'tax': item.tax,
    'total': item.total,
    'check_id': item.checkId,
    'is_takeout': item.isTakeout,
    'status': item.status,
    'notes': item.notes,
    'tax_mode': item.taxMode,
    'tax_rate': item.taxRate,
    'original_tax_rate': item.originalTaxRate,
    'print_area_code': item.printAreaCode,
    'created_at': item.createdAt.toIso8601String(),
    'created_by_employee_id': item.createdByEmployeeId,
    'created_by_employee_name': item.createdByEmployeeName,
    'modifiers': item.modifiers
        .map(
          (m) => {
            'id': m.id,
            'item_id': m.itemId,
            'name': m.name,
            'qty': m.qty,
            'price': m.price,
            'menu_item_id': m.menuItemId,
            'modifier_id': m.modifierId,
          },
        )
        .toList(growable: false),
    'tax_lines': item.taxLines
        .map(
          (t) => {
            'id': t.id,
            'order_item_id': t.orderItemId,
            'tax_id': t.taxId,
            'tax_name': t.taxName,
            'tax_rate': t.taxRate,
            'amount': t.amount,
            'created_at': t.createdAt.toIso8601String(),
          },
        )
        .toList(growable: false),
  };

  static OrderItem decode(Map<String, dynamic> map) =>
      OrderItem.fromMap(map).copyWith(
        total: (map['total'] as num?)?.toDouble(),
        createdByEmployeeName: map['created_by_employee_name']?.toString(),
        modifiers: ((map['modifiers'] as List?) ?? const [])
            .whereType<Map>()
            .map(
              (m) => OrderItemModifier.fromMap({
                ...Map<String, dynamic>.from(m),
                'item_id': map['id'],
              }),
            )
            .toList(growable: false),
        taxLines: ((map['tax_lines'] as List?) ?? const [])
            .whereType<Map>()
            .map(
              (t) => OrderItemTaxLine.fromMap({
                ...Map<String, dynamic>.from(t),
                'order_item_id': map['id'],
              }),
            )
            .toList(growable: false),
      );
}
