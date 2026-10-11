import 'package:equatable/equatable.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/models/fiscal_models.dart';

/// T04 (20261010_0006): otro equipo cambió lo que el operador estaba
/// editando y su cambio no se aplicó. La intención queda guardada en el VM: el
/// operador decide quedarse con lo de ahora o aplicar su cambio.
class EditConflictNotice extends Equatable {
  const EditConflictNotice({
    required this.id,
    required this.message,
    this.detail,
  });

  final String id;
  final String message;

  /// Lo que hay ahora en el servidor, en palabras.
  final String? detail;

  @override
  List<Object?> get props => [id, message, detail];
}

/// Qué tan al día está la cuenta en pantalla. Al abrir una mesa se pinta
/// primero la copia guardada y luego llega el servidor: mientras tanto
/// ([verifying]) la Pre-Cuenta no se puede imprimir (antes se imprimía sobre
/// esa copia y la recarga metía productos sin enviar sin avisar). Bandera
/// propia con tope de tiempo, no el `loading` general, que puede quedar
/// pegado.
enum AccountCheck {
  /// Leída del servidor en esta apertura (o sin copia previa que verificar).
  verified,

  /// Mostrando la copia guardada mientras responde el servidor.
  verifying,

  /// Sin servidor: se trabaja con la copia local (modo offline).
  localCopy,

  /// El servidor no respondió a tiempo: la copia puede estar vieja.
  refreshFailed,
}

class CurrentOrderState extends Equatable {
  final bool loading;
  final String? error;
  final Order? order;
  final List<OrderItem> items;
  final List<OrderCheck> checks;
  final bool takeout; // ¿para llevar? a nivel orden (UI toggle)
  final String? origin; // 'table' | 'manual' | 'quick' | 'delivery'
  final String? deliveryType; // 'own' | 'uber_eats' | 'pedidos_ya'
  final String? deliveryAddress; // dirección de entrega (delivery, opcional)
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

  /// Error real al cargar `ncf_sequences`. Si != null, distingue
  /// "no hay secuencias configuradas" de "fallo de red/RLS/auth".
  final String? fiscalSequencesLoadError;

  /// `taxes.id` de los impuestos que el cajero quitó a mano para ESTA orden
  /// desde el bloque de impuestos del carrito. Espejo de
  /// `order_excluded_taxes`: quien manda es el backend (que recalcula tasas y
  /// desglose), esto existe para que la UI no parpadee esperando el round-trip.
  final Set<String> excludedTaxIds;

  /// Conflicto de edición pendiente de la decisión del operador (T04).
  final EditConflictNotice? editConflict;

  /// Ver [AccountCheck].
  final AccountCheck accountCheck;

  const CurrentOrderState({
    this.loading = false,
    this.error,
    this.order,
    this.items = const [],
    this.checks = const [],
    this.takeout = false,
    this.origin,
    this.deliveryType,
    this.deliveryAddress,
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
    this.fiscalSequencesLoadError,
    this.excludedTaxIds = const {},
    this.editConflict,
    this.accountCheck = AccountCheck.verified,
  });

  CurrentOrderState copyWith({
    bool? loading,
    String? error,
    Order? order,
    bool clearOrder = false,
    List<OrderItem>? items,
    List<OrderCheck>? checks,
    bool? takeout,
    String? origin,
    bool clearOrigin = false,
    String? deliveryType,
    bool clearDeliveryType = false,
    String? deliveryAddress,
    bool clearDeliveryAddress = false,
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
    String? fiscalSequencesLoadError,
    bool clearFiscalSequencesLoadError = false,
    Set<String>? excludedTaxIds,
    EditConflictNotice? editConflict,
    bool clearEditConflict = false,
    AccountCheck? accountCheck,
  }) {
    return CurrentOrderState(
      loading: loading ?? this.loading,
      error: error,
      order: clearOrder ? null : (order ?? this.order),
      items: items ?? this.items,
      checks: checks ?? this.checks,
      takeout: takeout ?? this.takeout,
      origin: clearOrigin ? null : (origin ?? this.origin),
      deliveryType: clearDeliveryType
          ? null
          : (deliveryType ?? this.deliveryType),
      deliveryAddress: clearDeliveryAddress
          ? null
          : (deliveryAddress ?? this.deliveryAddress),
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
      fiscalSequencesLoadError: clearFiscalSequencesLoadError
          ? null
          : (fiscalSequencesLoadError ?? this.fiscalSequencesLoadError),
      excludedTaxIds: excludedTaxIds ?? this.excludedTaxIds,
      editConflict: clearEditConflict
          ? null
          : (editConflict ?? this.editConflict),
      accountCheck: accountCheck ?? this.accountCheck,
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
    deliveryAddress,
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
    fiscalSequencesLoadError,
    excludedTaxIds,
    editConflict,
    accountCheck,
  ];
}
