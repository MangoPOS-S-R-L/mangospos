import 'package:equatable/equatable.dart';
import 'package:mangopos/data/models/sales_models.dart';

class CurrentOrderState extends Equatable {
  final bool loading;
  final String? error;
  final Order? order;
  final List<OrderItem> items;
  final List<OrderCheck> checks;
  final bool takeout; // ¿para llevar? a nivel orden (UI toggle)
  final String? origin; // 'table' | 'manual' | 'quick'
  final String? selectedCheckId;
  final String? customerId;
  final String? customerName;
  final String? sessionNote;
  final bool isOfflineMode;
  final bool syncInFlight;
  final int pendingOfflineActions;
  final String? syncStatus;
  final DateTime? lastSyncAt;

  const CurrentOrderState({
    this.loading = false,
    this.error,
    this.order,
    this.items = const [],
    this.checks = const [],
    this.takeout = false,
    this.origin,
    this.selectedCheckId,
    this.customerId,
    this.customerName,
    this.sessionNote,
    this.isOfflineMode = false,
    this.syncInFlight = false,
    this.pendingOfflineActions = 0,
    this.syncStatus,
    this.lastSyncAt,
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
    String? selectedCheckId,
    bool clearSelectedCheck = false,
    String? customerId,
    String? customerName,
    bool clearCustomer = false,
    String? sessionNote,
    bool clearSessionNote = false,
    bool? isOfflineMode,
    bool? syncInFlight,
    int? pendingOfflineActions,
    String? syncStatus,
    DateTime? lastSyncAt,
  }) {
    return CurrentOrderState(
      loading: loading ?? this.loading,
      error: error,
      order: order ?? this.order,
      items: items ?? this.items,
      checks: checks ?? this.checks,
      takeout: takeout ?? this.takeout,
      origin: clearOrigin ? null : (origin ?? this.origin),
      selectedCheckId: clearSelectedCheck
          ? null
          : (selectedCheckId ?? this.selectedCheckId),
      customerId: clearCustomer ? null : (customerId ?? this.customerId),
      customerName: clearCustomer ? null : (customerName ?? this.customerName),
      sessionNote: clearSessionNote ? null : (sessionNote ?? this.sessionNote),
      isOfflineMode: isOfflineMode ?? this.isOfflineMode,
      syncInFlight: syncInFlight ?? this.syncInFlight,
      pendingOfflineActions: pendingOfflineActions ?? this.pendingOfflineActions,
      syncStatus: syncStatus,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
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
    selectedCheckId,
    customerId,
    customerName,
    sessionNote,
    isOfflineMode,
    syncInFlight,
    pendingOfflineActions,
    syncStatus,
    lastSyncAt,
  ];
}
