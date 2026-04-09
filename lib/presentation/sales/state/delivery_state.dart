import 'package:equatable/equatable.dart';

class DeliveryOrderSummary extends Equatable {
  final String sessionId;
  final String orderId;
  final String tableId;
  final String tableCode;
  final String deliveryType; // 'own', 'uber_eats', 'pedidos_ya'
  final String status; // 'open', 'sent', 'paid', etc.
  final double total;
  final int itemsCount;
  final DateTime openedAt;
  final String? customerName;

  const DeliveryOrderSummary({
    required this.sessionId,
    required this.orderId,
    required this.tableId,
    required this.tableCode,
    required this.deliveryType,
    required this.status,
    required this.total,
    required this.itemsCount,
    required this.openedAt,
    this.customerName,
  });

  factory DeliveryOrderSummary.fromMap(Map<String, dynamic> m) {
    return DeliveryOrderSummary(
      sessionId: (m['session_id'] ?? '') as String,
      orderId: (m['order_id'] ?? '') as String,
      tableId: (m['table_id'] ?? '') as String,
      tableCode: (m['table_code'] ?? '') as String,
      deliveryType: (m['delivery_type'] ?? 'own') as String,
      status: (m['status_ext'] ?? 'open') as String,
      total: (m['total'] as num?)?.toDouble() ?? 0,
      itemsCount: (m['items_count'] as num?)?.toInt() ?? 0,
      openedAt: DateTime.tryParse(m['opened_at']?.toString() ?? '') ??
          DateTime.now(),
      customerName: m['customer_name'] as String?,
    );
  }

  bool get isPendingPayment =>
      deliveryType == 'own' && status != 'paid';

  bool get isExternalPlatform =>
      deliveryType == 'uber_eats' || deliveryType == 'pedidos_ya';

  String get deliveryLabel {
    switch (deliveryType) {
      case 'uber_eats':
        return 'Uber Eats';
      case 'pedidos_ya':
        return 'Pedidos Ya';
      default:
        return 'Delivery Propio';
    }
  }

  @override
  List<Object?> get props => [
        sessionId, orderId, tableId, tableCode,
        deliveryType, status, total, itemsCount,
        openedAt, customerName,
      ];
}

class DeliveryState extends Equatable {
  final List<DeliveryOrderSummary> orders;
  final bool loading;
  final String? error;
  final String? businessId;

  const DeliveryState({
    this.orders = const [],
    this.loading = false,
    this.error,
    this.businessId,
  });

  DeliveryState copyWith({
    List<DeliveryOrderSummary>? orders,
    bool? loading,
    String? error,
    String? businessId,
  }) {
    return DeliveryState(
      orders: orders ?? this.orders,
      loading: loading ?? this.loading,
      error: error,
      businessId: businessId ?? this.businessId,
    );
  }

  @override
  List<Object?> get props => [orders, loading, error, businessId];
}
