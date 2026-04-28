import 'package:equatable/equatable.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/models/fiscal_models.dart';

class CurrentOrderState extends Equatable {
  final bool loading;
  final String? error;
  final Order? order;
  final List<OrderItem> items;
  final List<OrderCheck> checks;
  final bool takeout; // ¿para llevar? a nivel orden (UI toggle)
  final String? origin; // 'table' | 'manual' | 'quick' | 'delivery'
  final String? deliveryType; // 'own' | 'uber_eats' | 'pedidos_ya'
  final String? selectedCheckId;
  final String? customerId;
  final String? customerName;
  final String? customerLegalName;
  final String? sessionNote;
  final bool isOfflineMode;
  final bool syncInFlight;
  final int pendingOfflineActions;
  final String? syncStatus;
  final DateTime? lastSyncAt;
  final String fiscalType; // '01', '02', '31', '32', etc.
  final String fiscalDefaultType; // Default from fiscal_settings
  final List<FiscalNcfSequence> fiscalSequences;
  final String? customerTaxId;

  /// Mensaje de error si la configuración fiscal no se pudo cargar.
  /// Cuando es != null, los pagos deben bloquearse (PRD 1).
  final String? taxConfigError;

  const CurrentOrderState({
    this.loading = false,
    this.error,
    this.order,
    this.items = const [],
    this.checks = const [],
    this.takeout = false,
    this.origin,
    this.deliveryType,
    this.selectedCheckId,
    this.customerId,
    this.customerName,
    this.customerLegalName,
    this.sessionNote,
    this.isOfflineMode = false,
    this.syncInFlight = false,
    this.pendingOfflineActions = 0,
    this.syncStatus,
    this.lastSyncAt,
    this.fiscalType = '',
    this.fiscalDefaultType = '',
    this.fiscalSequences = const [],
    this.customerTaxId,
    this.taxConfigError,
  });

  CurrentOrderState copyWith({
    bool? loading,
    String? error,
    Order? order,
    List<OrderItem>? items,
    List<OrderCheck>? checks,
    bool? takeout,
    String? origin,
    bool clearOrigin = false,
    String? deliveryType,
    bool clearDeliveryType = false,
    String? selectedCheckId,
    bool clearSelectedCheck = false,
    String? customerId,
    String? customerName,
    String? customerLegalName,
    bool clearCustomer = false,
    String? sessionNote,
    bool clearSessionNote = false,
    bool? isOfflineMode,
    bool? syncInFlight,
    int? pendingOfflineActions,
    String? syncStatus,
    DateTime? lastSyncAt,
    String? fiscalType,
    String? fiscalDefaultType,
    List<FiscalNcfSequence>? fiscalSequences,
    String? customerTaxId,
    String? taxConfigError,
    bool clearTaxConfigError = false,
  }) {
    return CurrentOrderState(
      loading: loading ?? this.loading,
      error: error,
      order: order ?? this.order,
      items: items ?? this.items,
      checks: checks ?? this.checks,
      takeout: takeout ?? this.takeout,
      origin: clearOrigin ? null : (origin ?? this.origin),
      deliveryType: clearDeliveryType
          ? null
          : (deliveryType ?? this.deliveryType),
      selectedCheckId: clearSelectedCheck
          ? null
          : (selectedCheckId ?? this.selectedCheckId),
      customerId: clearCustomer ? null : (customerId ?? this.customerId),
      customerName: clearCustomer ? null : (customerName ?? this.customerName),
      customerLegalName: clearCustomer
          ? null
          : (customerLegalName ?? this.customerLegalName),
      sessionNote: clearSessionNote ? null : (sessionNote ?? this.sessionNote),
      isOfflineMode: isOfflineMode ?? this.isOfflineMode,
      syncInFlight: syncInFlight ?? this.syncInFlight,
      pendingOfflineActions:
          pendingOfflineActions ?? this.pendingOfflineActions,
      syncStatus: syncStatus,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      fiscalType: fiscalType ?? this.fiscalType,
      fiscalDefaultType: fiscalDefaultType ?? this.fiscalDefaultType,
      fiscalSequences: fiscalSequences ?? this.fiscalSequences,
      customerTaxId: clearCustomer
          ? null
          : (customerTaxId ?? this.customerTaxId),
      taxConfigError: clearTaxConfigError
          ? null
          : (taxConfigError ?? this.taxConfigError),
    );
  }

  @override
  List<Object?> get props => [
    loading,
    error,
    order,
    items,
    checks,
    takeout,
    origin,
    deliveryType,
    selectedCheckId,
    customerId,
    customerName,
    customerLegalName,
    sessionNote,
    isOfflineMode,
    syncInFlight,
    pendingOfflineActions,
    syncStatus,
    lastSyncAt,
    fiscalType,
    fiscalDefaultType,
    fiscalSequences,
    customerTaxId,
    taxConfigError,
  ];
}
