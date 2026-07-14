import 'package:equatable/equatable.dart';
import '../../../data/models/bank_account.dart';
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

  // Cuenta bancaria seleccionada (solo aplica para transferencias). Las
  // cuentas se administran desde Ajustes → Tipos de Pago. Cuando el
  // cajero elige el método 'transfer', el modal le muestra un selector
  // con las cuentas activas del negocio. Persistido en
  // payments.bank_account_id para trazabilidad.
  final BankAccount? selectedBankAccount;

  // Cliente (para factura)
  final String? customerId;
  final String? customerRnc;
  final String? customerName;

  // Tipo de comprobante fiscal
  // Tipos disponibles del business (ncf_sequences activas con rango libre).
  // Ej: ['B02', 'E32'] o ['B02', 'E31', 'E32'] segun config del business.
  final List<String> availableNcfTypes;
  // Tipo seleccionado por el cajero. Default = default_ncf_type del business.
  final String? selectedNcfType;
  // True si el business tiene e-CF habilitado (al menos una sequence Exx activa).
  final bool ecfEnabled;

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
    this.selectedBankAccount,
    this.customerId,
    this.customerRnc,
    this.customerName,
    this.availableNcfTypes = const [],
    this.selectedNcfType,
    this.ecfEnabled = false,
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
    Object? selectedBankAccount = _sentinel,
    String? customerId,
    String? customerRnc,
    String? customerName,
    List<String>? availableNcfTypes,
    String? selectedNcfType,
    bool? ecfEnabled,
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
      // Sentinel para diferenciar "no se pasó" de "se pasó null
      // explícitamente" (ej. limpiar selección al cambiar de método).
      selectedBankAccount: identical(selectedBankAccount, _sentinel)
          ? this.selectedBankAccount
          : selectedBankAccount as BankAccount?,
      customerId: customerId ?? this.customerId,
      customerRnc: customerRnc ?? this.customerRnc,
      customerName: customerName ?? this.customerName,
      availableNcfTypes: availableNcfTypes ?? this.availableNcfTypes,
      selectedNcfType: selectedNcfType ?? this.selectedNcfType,
      ecfEnabled: ecfEnabled ?? this.ecfEnabled,
      processingPayment: processingPayment ?? this.processingPayment,
      paymentProcessed: paymentProcessed ?? this.paymentProcessed,
      processedPayment: processedPayment ?? this.processedPayment,
      fiscalDocument: fiscalDocument ?? this.fiscalDocument,
      offlineQueued: offlineQueued ?? this.offlineQueued,
    );
  }

  /// True si el tipo seleccionado requiere RNC del comprador.
  /// E31 (Crédito Fiscal) y E33/E34 contra créditos requieren RNC.
  bool get requiresCustomerRnc {
    final t = selectedNcfType;
    if (t == null) return false;
    return t == 'E31' || t == 'E33' || t == 'E34' || t == 'B01';
  }

  /// True si el RNC del comprador está poblado y bien formateado (9 u 11 dígitos).
  bool get hasValidCustomerRnc {
    final rnc = customerRnc?.trim() ?? '';
    if (rnc.isEmpty) return false;
    return RegExp(r'^\d{9}$|^\d{11}$').hasMatch(rnc);
  }

  bool get canProcessPayment {
    if (selectedMethod == null) return false;
    if (loading || processingPayment) return false;
    if (paymentProcessed) return false;

    // Si hay un error (ej: falta sesión de caja), no permitir pago
    if (error != null) return false;

    // Comprobantes que exigen RNC del comprador (E31, E33, E34, B01).
    if (requiresCustomerRnc && !hasValidCustomerRnc) {
      return false;
    }

    // Para efectivo, debe recibir al menos el total
    if (selectedMethod!.isCash) {
      return amountReceived >= totalToPay;
    }

    // Venta a crédito: exige cliente asignado (la cuenta por cobrar se
    // registra a su nombre). Límite/habilitación se validan al procesar
    // (consulta online) y el trigger server-side es el backstop.
    if (isCreditPayment) {
      return customerId != null && customerId!.isNotEmpty;
    }

    // Para transferencia, exigimos seleccionar la cuenta destino. La
    // referencia es opcional por ahora (puede que el cajero la cargue
    // después de validar manual con el cliente).
    if (isTransferPayment) {
      if (selectedBankAccount == null) return false;
    }

    // Para métodos que requieren referencia
    if (requiresReference) {
      return reference != null && reference!.isNotEmpty;
    }

    // Para otros métodos, siempre puede procesar
    return true;
  }

  bool get isCashPayment => selectedMethod?.isCash ?? false;
  bool get isCreditPayment => selectedMethod?.isCredit ?? false;
  bool get requiresReference => selectedMethod?.requiresReference ?? false;

  /// `true` si el método activo es transferencia. Match defensivo:
  /// algunos businesses tienen el code en español ('transferencia') o
  /// con mayúsculas, y otros llegan con code vacío y solo el name. Se
  /// chequea code exacto Y se cae al name que contenga "transfer" si
  /// el code no matchea — así el selector funciona aunque el seed
  /// del payment_method tenga variaciones.
  bool get isTransferPayment {
    final m = selectedMethod;
    if (m == null) return false;
    final code = m.code.toLowerCase().trim();
    if (code == 'transfer' || code == 'transferencia') return true;
    final name = m.name.toLowerCase();
    return name.contains('transfer');
  }

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
    selectedBankAccount,
    customerId,
    customerRnc,
    customerName,
    availableNcfTypes,
    selectedNcfType,
    ecfEnabled,
    processingPayment,
    paymentProcessed,
    processedPayment,
    fiscalDocument,
    offlineQueued,
  ];
}

/// Sentinel privado para diferenciar "no se pasó argumento" de "se pasó
/// null explícito" en `copyWith`. Sin esto, no podemos limpiar campos
/// nullable como `selectedBankAccount`.
const Object _sentinel = Object();
