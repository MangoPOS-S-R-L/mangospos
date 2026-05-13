import 'package:equatable/equatable.dart';

/// 💳 Método de pago
class PaymentMethod extends Equatable {
  final String id;
  final String businessId;
  final String name;
  final String code; // 'cash', 'card', 'transfer', 'qr'
  final bool isActive;
  final bool requiresReference;
  final String? icon;
  final int position;

  const PaymentMethod({
    required this.id,
    required this.businessId,
    required this.name,
    required this.code,
    required this.isActive,
    required this.requiresReference,
    this.icon,
    required this.position,
  });

  factory PaymentMethod.fromMap(Map<String, dynamic> map) {
    return PaymentMethod(
      id: map['id'] ?? '',
      businessId: map['business_id'] ?? '',
      name: map['name'] ?? '',
      code: map['code'] ?? '',
      isActive: map['is_active'] ?? true,
      requiresReference: map['requires_reference'] ?? false,
      icon: map['icon'],
      position: map['position'] ?? 0,
    );
  }

  bool get isCash => code == 'cash';
  bool get isCard => code == 'card';
  bool get isTransfer => code == 'transfer';
  bool get isQR => code == 'qr';

  @override
  List<Object?> get props => [
    id,
    businessId,
    name,
    code,
    isActive,
    requiresReference,
    icon,
    position,
  ];
}

/// 💰 Sesión de caja
class CashRegisterSession extends Equatable {
  final String id;
  final String cashRegisterId;
  final String userId;
  final DateTime openedAt;
  final DateTime? closedAt;
  final double startAmount;
  final double? endAmount;
  final double difference;
  final String status; // 'open', 'closed'
  final String? notes;

  const CashRegisterSession({
    required this.id,
    required this.cashRegisterId,
    required this.userId,
    required this.openedAt,
    this.closedAt,
    required this.startAmount,
    this.endAmount,
    required this.difference,
    required this.status,
    this.notes,
  });

  factory CashRegisterSession.fromMap(Map<String, dynamic> map) {
    return CashRegisterSession(
      id: map['id'] ?? '',
      cashRegisterId: map['cash_register_id'] ?? '',
      userId: map['user_id'] ?? '',
      openedAt: DateTime.tryParse(map['opened_at'] ?? '') ?? DateTime.now(),
      closedAt: map['closed_at'] != null
          ? DateTime.tryParse(map['closed_at'])
          : null,
      startAmount: (map['start_amount'] ?? 0).toDouble(),
      endAmount: map['end_amount'] != null
          ? (map['end_amount']).toDouble()
          : null,
      difference: (map['difference'] ?? 0).toDouble(),
      status: map['status'] ?? 'open',
      notes: map['notes'],
    );
  }

  bool get isOpen => status == 'open' && closedAt == null;
  bool get isClosed => status == 'closed' || closedAt != null;

  Map<String, dynamic> toMap() => {
        'id': id,
        'cash_register_id': cashRegisterId,
        'user_id': userId,
        'opened_at': openedAt.toIso8601String(),
        'closed_at': closedAt?.toIso8601String(),
        'start_amount': startAmount,
        'end_amount': endAmount,
        'difference': difference,
        'status': status,
        'notes': notes,
      };

  @override
  List<Object?> get props => [
    id,
    cashRegisterId,
    userId,
    openedAt,
    closedAt,
    startAmount,
    endAmount,
    difference,
    status,
    notes,
  ];
}

/// 🧾 Transacción de caja
class CashTransaction extends Equatable {
  final String id;
  final String sessionId;
  final double amount;
  final String type; // 'sale', 'expense', 'withdrawal', 'deposit'
  final String? description;
  final String? relatedOrderId;
  final DateTime createdAt;

  /// Sprint Caja Pro — code de la razón estructurada (catálogo
  /// `cash_transaction_reasons`). NULL en transacciones legacy o
  /// generadas por el sistema (ventas).
  final String? reasonCode;

  const CashTransaction({
    required this.id,
    required this.sessionId,
    required this.amount,
    required this.type,
    this.description,
    this.relatedOrderId,
    required this.createdAt,
    this.reasonCode,
  });

  factory CashTransaction.fromMap(Map<String, dynamic> map) {
    return CashTransaction(
      id: map['id'] ?? '',
      sessionId: map['session_id'] ?? '',
      amount: (map['amount'] ?? 0).toDouble(),
      type: map['type'] ?? 'sale',
      description: map['description'],
      relatedOrderId: map['related_order_id'],
      createdAt: DateTime.tryParse(map['created_at'] ?? '') ?? DateTime.now(),
      reasonCode: map['reason_code'] as String?,
    );
  }

  @override
  List<Object?> get props => [
    id,
    sessionId,
    amount,
    type,
    description,
    relatedOrderId,
    createdAt,
    reasonCode,
  ];
}

/// 💵 Información de pago para procesar
class PaymentInfo {
  final String orderId;
  final String? checkId;
  final String paymentMethodId;
  final double amount;
  final String? reference;
  final String? customerId;
  final String? customerRnc;
  final double changeAmount;

  const PaymentInfo({
    required this.orderId,
    this.checkId,
    required this.paymentMethodId,
    required this.amount,
    this.reference,
    this.customerId,
    this.customerRnc,
    this.changeAmount = 0,
  });

  Map<String, dynamic> toMap() => {
    'order_id': orderId,
    'check_id': checkId,
    'payment_method_id': paymentMethodId,
    'amount': amount,
    'reference': reference,
    'customer_id': customerId,
    'customer_rnc': customerRnc,
    'change_amount': changeAmount,
  };
}
