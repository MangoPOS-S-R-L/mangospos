import 'package:equatable/equatable.dart';

class OrderItem extends Equatable {
  final String id;
  final String orderId;
  final String? checkId;
  final String? productId;
  final String productName;
  final double qty;
  final double unitPrice;
  final bool isTakeout;
  final String status;
  final String? notes;
  final double subtotal;
  final double discounts;
  final double tax;
  final double total;
  // Oferta/promoción aplicada a esta línea (atribución para aplicar promos en
  // todos los flujos y para el reporte de ventas por oferta). Null = sin oferta.
  final String? promotionId;

  const OrderItem({
    required this.id,
    required this.orderId,
    this.checkId,
    this.productId,
    required this.productName,
    required this.qty,
    required this.unitPrice,
    required this.isTakeout,
    required this.status,
    this.notes,
    required this.subtotal,
    required this.discounts,
    required this.tax,
    required this.total,
    this.promotionId,
  });

  factory OrderItem.fromMap(Map<String, dynamic> map) {
    return OrderItem(
      id: map['id'] ?? '',
      orderId: map['order_id'] ?? '',
      checkId: map['check_id'],
      productId: map['product_id'],
      productName: map['product_name'] ?? '',
      qty: (map['qty'] ?? map['quantity'] ?? 1).toDouble(),
      unitPrice: (map['unit_price'] ?? 0).toDouble(),
      isTakeout: map['is_takeout'] ?? false,
      status: map['status'] ?? 'pending',
      notes: map['notes'],
      subtotal: (map['subtotal'] ?? 0).toDouble(),
      discounts: (map['discounts'] ?? 0).toDouble(),
      tax: (map['tax'] ?? 0).toDouble(),
      total: (map['total'] ?? 0).toDouble(),
      promotionId: map['promotion_id'],
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'order_id': orderId,
    'check_id': checkId,
    'product_id': productId,
    'product_name': productName,
    'qty': qty,
    'unit_price': unitPrice,
    'is_takeout': isTakeout,
    'status': status,
    'notes': notes,
    'subtotal': subtotal,
    'discounts': discounts,
    'tax': tax,
    'total': total,
    'promotion_id': promotionId,
  };

  @override
  List<Object?> get props => [
    id,
    orderId,
    productName,
    qty,
    unitPrice,
    isTakeout,
    status,
    subtotal,
    total,
    promotionId,
  ];
}
