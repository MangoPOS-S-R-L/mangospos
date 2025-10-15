class OrderDetail {
  final String orderId;
  final String checkId;
  final int checkPos;
  final String checkLabel;
  final String itemId;
  final String productName;
  final double qty;
  final double unitPrice;
  final bool isTakeout;
  final String status;
  final String? notes;
  final double itemTotal;
  final double orderTotal;

  OrderDetail({
    required this.orderId,
    required this.checkId,
    required this.checkPos,
    required this.checkLabel,
    required this.itemId,
    required this.productName,
    required this.qty,
    required this.unitPrice,
    required this.isTakeout,
    required this.status,
    this.notes,
    required this.itemTotal,
    required this.orderTotal,
  });

  factory OrderDetail.fromMap(Map<String, dynamic> map) => OrderDetail(
        orderId: map['order_id'],
        checkId: map['check_id'],
        checkPos: map['check_pos'],
        checkLabel: map['check_label'],
        itemId: map['item_id'],
        productName: map['product_name'] ?? '',
        qty: (map['qty'] ?? 1).toDouble(),
        unitPrice: (map['unit_price'] ?? 0).toDouble(),
        isTakeout: map['is_takeout'] ?? false,
        status: map['status'] ?? '',
        notes: map['notes'],
        itemTotal: (map['total'] ?? 0).toDouble(),
        orderTotal: (map['order_total'] ?? 0).toDouble(),
      );
}
