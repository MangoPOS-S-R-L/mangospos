import 'package:equatable/equatable.dart';
import '../../../data/models/payment_models.dart';
import '../../../data/models/sales_models.dart';

/// 💰 Estado del proceso de pago
class PaymentState extends Equatable {
  final bool loading;
  final String? error;

  // Orden y check
  final Order? order;
  final OrderCheck? check;
  final double totalToPay;

  // Métodos de pago disponibles
  final List<PaymentMethod> paymentMethods;
  final PaymentMethod? selectedMethod;

  // Sesión de caja
  final CashRegisterSession? cashSession;

  // Pago en efectivo
  final double amountReceived;
  final double change;

  // Referencia (para tarjeta/transferencia)
  final String? reference;

  // Cliente (para factura)
  final String? customerId;
  final String? customerRnc;
  final String? customerName;

  // Estado del proceso
  final bool processingPayment; // true while payment RPC is in flight
  final bool paymentProcessed;
  final Payment? processedPayment;
  final FiscalDocument? fiscalDocument;
  final bool offlineQueued;

  const PaymentState({
    this.loading = false,
    this.error,
    this.order,
    this.check,
    this.totalToPay = 0,
    this.paymentMethods = const [],
    this.selectedMethod,
    this.cashSession,
    this.amountReceived = 0,
    this.change = 0,
    this.reference,
    this.customerId,
    this.customerRnc,
    this.customerName,
    this.processingPayment = false,
    this.paymentProcessed = false,
    this.processedPayment,
    this.fiscalDocument,
    this.offlineQueued = false,
  });

  PaymentState copyWith({
    bool? loading,
    String? error,
    Order? order,
    OrderCheck? check,
    double? totalToPay,
    List<PaymentMethod>? paymentMethods,
    PaymentMethod? selectedMethod,
    CashRegisterSession? cashSession,
    double? amountReceived,
    double? change,
    String? reference,
    String? customerId,
    String? customerRnc,
    String? customerName,
    bool? processingPayment,
    bool? paymentProcessed,
    Payment? processedPayment,
    FiscalDocument? fiscalDocument,
    bool? offlineQueued,
  }) {
    return PaymentState(
      loading: loading ?? this.loading,
      error: error,
      order: order ?? this.order,
      check: check ?? this.check,
      totalToPay: totalToPay ?? this.totalToPay,
      paymentMethods: paymentMethods ?? this.paymentMethods,
      selectedMethod: selectedMethod ?? this.selectedMethod,
      cashSession: cashSession ?? this.cashSession,
      amountReceived: amountReceived ?? this.amountReceived,
      change: change ?? this.change,
      reference: reference ?? this.reference,
      customerId: customerId ?? this.customerId,
      customerRnc: customerRnc ?? this.customerRnc,
      customerName: customerName ?? this.customerName,
      processingPayment: processingPayment ?? this.processingPayment,
      paymentProcessed: paymentProcessed ?? this.paymentProcessed,
      processedPayment: processedPayment ?? this.processedPayment,
      fiscalDocument: fiscalDocument ?? this.fiscalDocument,
      offlineQueued: offlineQueued ?? this.offlineQueued,
    );
  }

  bool get canProcessPayment {
    if (selectedMethod == null) return false;
    if (loading || processingPayment) return false;
    if (paymentProcessed) return false;

    // Si hay un error (ej: falta sesión de caja), no permitir pago
    if (error != null) return false;

    // Para efectivo, debe recibir al menos el total
    if (selectedMethod!.isCash) {
      return amountReceived >= totalToPay;
    }

    // Para métodos que requieren referencia
    if (requiresReference) {
      return reference != null && reference!.isNotEmpty;
    }

    // Para otros métodos, siempre puede procesar
    return true;
  }

  bool get isCashPayment => selectedMethod?.isCash ?? false;
  bool get requiresReference => selectedMethod?.requiresReference ?? false;

  @override
  List<Object?> get props => [
    loading,
    error,
    order,
    check,
    totalToPay,
    paymentMethods,
    selectedMethod,
    cashSession,
    amountReceived,
    change,
    reference,
    customerId,
    customerRnc,
    customerName,
    processingPayment,
    paymentProcessed,
    processedPayment,
    fiscalDocument,
    offlineQueued,
  ];
}
