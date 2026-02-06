import 'package:equatable/equatable.dart';

class Order extends Equatable {
  final String id;
  final String sessionId;
  final String status;
  final double subtotal;
  final double discounts;
  final double tax;
  final double total;
  final DateTime createdAt;

  const Order({
    required this.id,
    required this.sessionId,
    required this.status,
    required this.subtotal,
    required this.discounts,
    required this.tax,
    required this.total,
    required this.createdAt,
  });

  factory Order.fromMap(Map<String, dynamic> map) {
    return Order(
      id: map['id'] ?? '',
      sessionId: map['session_id'] ?? '',
      status: map['status_ext'] ?? 'open',
      subtotal: (map['subtotal'] ?? 0).toDouble(),
      discounts: (map['discounts'] ?? 0).toDouble(),
      tax: (map['tax'] ?? 0).toDouble(),
      total: (map['total'] ?? 0).toDouble(),
      createdAt: DateTime.tryParse(map['created_at'] ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'session_id': sessionId,
    'status_ext': status,
    'subtotal': subtotal,
    'discounts': discounts,
    'tax': tax,
    'total': total,
    'created_at': createdAt.toIso8601String(),
  };

  Order copyWith({
    String? id,
    String? sessionId,
    String? status,
    double? subtotal,
    double? discounts,
    double? tax,
    double? total,
    DateTime? createdAt,
  }) {
    return Order(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      status: status ?? this.status,
      subtotal: subtotal ?? this.subtotal,
      discounts: discounts ?? this.discounts,
      tax: tax ?? this.tax,
      total: total ?? this.total,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  List<Object?> get props => [
    id,
    sessionId,
    status,
    subtotal,
    discounts,
    tax,
    total,
    createdAt,
  ];
}
