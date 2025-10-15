import 'package:equatable/equatable.dart';

class Check extends Equatable {
  final String id;
  final String orderId;
  final int position;
  final String label;
  final bool isClosed;
  final double subtotal;
  final double discounts;
  final double tax;
  final double total;

  const Check({
    required this.id,
    required this.orderId,
    required this.position,
    required this.label,
    required this.isClosed,
    required this.subtotal,
    required this.discounts,
    required this.tax,
    required this.total,
  });

  factory Check.fromMap(Map<String, dynamic> map) {
    return Check(
      id: map['id'] ?? '',
      orderId: map['order_id'] ?? '',
      position: map['position'] ?? 1,
      label: map['label'] ?? 'C1',
      isClosed: map['is_closed'] ?? false,
      subtotal: (map['subtotal'] ?? 0).toDouble(),
      discounts: (map['discounts'] ?? 0).toDouble(),
      tax: (map['tax'] ?? 0).toDouble(),
      total: (map['total'] ?? 0).toDouble(),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'order_id': orderId,
        'position': position,
        'label': label,
        'is_closed': isClosed,
        'subtotal': subtotal,
        'discounts': discounts,
        'tax': tax,
        'total': total,
      };

  @override
  List<Object?> get props =>
      [id, orderId, position, label, isClosed, subtotal, discounts, tax, total];
}
