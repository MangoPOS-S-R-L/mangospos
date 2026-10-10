import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/fiscal/ncf_types.dart';
import '../../../core/fiscal/payment_stage.dart';
import '../../../core/fiscal/sales_note_policy.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../core/performance/performance_diagnostics.dart';
import '../../../core/offline/offline_ncf_service.dart';
import '../../../core/offline/offline_pos_service.dart';
import '../../../core/offline/hub/hub_payment_mirror.dart';
import '../../../core/offline/payment_intent_journal.dart';
import '../../../core/utils/device_utils.dart';
import '../../../data/models/bank_account.dart';
import '../../../data/models/payment_attempt_lease.dart';
import '../../../data/models/sales_models.dart';

import '../../../data/repositories/cashier_repository.dart';
import '../../../data/repositories/pos_settings_repository.dart';
import '../../../data/repositories/sales_repository_improved.dart';
import '../../../data/repositories/table_deposit_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../../cashier/viewmodel/cashier_viewmodel.dart';
import '../viewmodel/sales_viewmodel.dart';
import '../../../services/session/session_controller.dart';

// ==============================================================================
// 📦 MODELS
// ==============================================================================

enum PaymentMethodType { cash, card, transfer, tableDeposit, other }

/// Sentinel para diferenciar "no se pasó argumento" de "se pasó null
/// explícito" en `PaymentSplitState.copyWith` (sin esto no podríamos
/// limpiar `selectedBankAccount` al cambiar de método de pago).
const Object _bankSentinel = Object();

/// Mismo truco que `_bankSentinel`, para poder *limpiar* el NCF emitido al
/// arrancar un cobro nuevo. Sin esto `copyWith` no distingue "no me pasaron
/// nada" de "ponlo en null", y el estado final del segundo cobro mostraria el
/// comprobante del primero.
const Object _ncfSentinel = Object();

/// Igual para el aviso de cobro recuperado: poder limpiarlo al terminar.
const Object _noticeSentinel = Object();

class PaymentTransaction {
  final String id;
  final PaymentMethodType method;
  final double amount;
  final DateTime timestamp;
  final String? reference; // For card ref, auth code, etc.
  /// Cuenta bancaria a la que llegó la transferencia. Null para
  /// efectivo/tarjeta y para transferencias legacy donde no se eligió
  /// cuenta. Se persiste en `payments.bank_account_id` al confirmar.
  final BankAccount? bankAccount;

  PaymentTransaction({
    required this.id,
    required this.method,
    required this.amount,
    required this.timestamp,
    this.reference,
    this.bankAccount,
  });

  String get methodLabel {
    switch (method) {
      case PaymentMethodType.cash:
        return 'Efectivo';
      case PaymentMethodType.card:
        return 'Tarjeta';
      case PaymentMethodType.transfer:
        return 'Transferencia';
      case PaymentMethodType.tableDeposit:
        return 'Saldo de mesa';
      case PaymentMethodType.other:
        return 'Otro';
    }
  }
}

class PaymentSplitState {
  final double totalAmount;
  final List<PaymentTransaction> transactions;
  final String currentInput; // String to handle "10." typing
  final PaymentMethodType activeMethod;
  final bool isProcessing;

  /// Qué se está esperando ahora mismo. `isProcessing`/`isPrinting` siguen
  /// siendo los interruptores que bloquean la UI; esto solo dice el porqué.
  /// Mismo enum que usa el modal de cobro simple (`presentation/payments`)
  /// para que los dos flujos de cobro se lean igual.
  final PaymentStage stage;

  /// La emisión e-CF no completó dentro del timeout de `emit-document` y el
  /// comprobante sale en contingencia. No es un error: la venta quedó
  /// registrada y el ticket se imprime igual; el cron de respaldo y el
  /// webhook lo reenvían a la DGII. Va aparte de `stage` porque es el
  /// resultado de la etapa DGII y tiene que seguir visible cuando el flujo
  /// ya avanzó a `imprimiendo`.
  final bool dgiiContingency;

  /// NCF emitido para este cobro, para mostrarlo en el estado final. Sale del
  /// `fiscal_document` que el RPC ya creo — no hay round-trip extra, es la
  /// misma consulta que ya se hacia para la emision e-CF.
  final String? emittedNcf;

  /// Fase post-cobro: el pago ya esta grabado en DB pero la impresion del
  /// ticket esta en curso. Mientras `isPrinting=true` el modal NO debe
  /// cerrarse y los botones de salir/cancelar quedan bloqueados — sino el
  /// cajero puede liberar la mesa sin haber visto el ticket.
  final bool isPrinting;
  final String? error;
  final String? validationError;
  final Order? orderDetails; // For printing
  final List<OrderItem> orderItems; // For printing
  /// Cuenta bancaria seleccionada para el próximo `addTransaction` cuando
  /// el método activo es transferencia. Se limpia al cambiar de método.
  final BankAccount? selectedBankAccount;

  /// True cuando el cobro no pudo llegar al server y se encoló para sync.
  /// El caller usa este flag para imprimir precuenta en vez de factura
  /// (NCF se emite al sincronizar, no antes).
  final bool offlineQueued;

  /// F4: NCF de papel asignado offline (Hub) para este cobro. Cuando viene,
  /// el caller imprime el COMPROBANTE con este número en el acto en vez de la
  /// precuenta. Null = sin NCF offline (provisional / online).
  final String? offlineNcf;

  // ── Nota de venta (documento NO fiscal) ──
  /// Este cobro es consumidor final, solo efectivo y todavía tiene notas
  /// disponibles en el ciclo configurado del negocio.
  final bool salesNoteAvailable;

  /// El cajero eligió cobrar con nota de venta: esta venta no consume NCF.
  final bool salesNoteSelected;

  /// Número de la nota emitida al cerrar el cobro (`NV-000123`), para
  /// mostrarlo en el estado final igual que se muestra el NCF.
  final String? emittedSalesNote;

  // ── Abono / saldo prepagado de la mesa ──
  /// Saldo que la mesa tiene abonado. `null` mientras carga, y
  /// `TableDepositAccount.empty` cuando la mesa no tiene saldo (o la venta no
  /// es de mesa). El método "Saldo de mesa" solo aparece cuando hay saldo.
  final TableDepositAccount? tableDeposit;

  /// Aviso de que se recuperó (o se encontró) un cobro que quedó a medias al
  /// cerrarse la app. A diferencia de `error`, no se borra en cada cambio de
  /// estado: el cajero tiene que verlo mientras termina ese cobro.
  final String? resumedAttemptNotice;

  const PaymentSplitState({
    this.totalAmount = 0,
    this.transactions = const [],
    this.currentInput = '',
    this.activeMethod = PaymentMethodType.cash,
    this.isProcessing = false,
    this.stage = PaymentStage.idle,
    this.dgiiContingency = false,
    this.emittedNcf,
    this.isPrinting = false,
    this.error,
    this.validationError,
    this.orderDetails,
    this.orderItems = const [],
    this.selectedBankAccount,
    this.offlineQueued = false,
    this.offlineNcf,
    this.salesNoteAvailable = false,
    this.salesNoteSelected = false,
    this.emittedSalesNote,
    this.tableDeposit,
    this.resumedAttemptNotice,
  });

  PaymentSplitState copyWith({
    double? totalAmount,
    List<PaymentTransaction>? transactions,
    String? currentInput,
    PaymentMethodType? activeMethod,
    bool? isProcessing,
    PaymentStage? stage,
    bool? dgiiContingency,
    Object? emittedNcf = _ncfSentinel,
    bool? isPrinting,
    String? error,
    String? validationError,
    Order? orderDetails,
    List<OrderItem>? orderItems,
    Object? selectedBankAccount = _bankSentinel,
    bool? offlineQueued,
    String? offlineNcf,
    bool? salesNoteAvailable,
    bool? salesNoteSelected,
    String? emittedSalesNote,
    TableDepositAccount? tableDeposit,
    Object? resumedAttemptNotice = _noticeSentinel,
  }) {
    return PaymentSplitState(
      totalAmount: totalAmount ?? this.totalAmount,
      transactions: transactions ?? this.transactions,
      currentInput: currentInput ?? this.currentInput,
      activeMethod: activeMethod ?? this.activeMethod,
      isProcessing: isProcessing ?? this.isProcessing,
      stage: stage ?? this.stage,
      dgiiContingency: dgiiContingency ?? this.dgiiContingency,
      emittedNcf: identical(emittedNcf, _ncfSentinel)
          ? this.emittedNcf
          : emittedNcf as String?,
      isPrinting: isPrinting ?? this.isPrinting,
      error: error,
      validationError: validationError,
      orderDetails: orderDetails ?? this.orderDetails,
      orderItems: orderItems ?? this.orderItems,
      // Sentinel para diferenciar "no se pasó" vs "se pasó null para
      // limpiar la selección" (e.g. al cambiar de método de pago).
      selectedBankAccount: identical(selectedBankAccount, _bankSentinel)
          ? this.selectedBankAccount
          : selectedBankAccount as BankAccount?,
      offlineQueued: offlineQueued ?? this.offlineQueued,
      offlineNcf: offlineNcf ?? this.offlineNcf,
      salesNoteAvailable: salesNoteAvailable ?? this.salesNoteAvailable,
      salesNoteSelected: salesNoteSelected ?? this.salesNoteSelected,
      emittedSalesNote: emittedSalesNote ?? this.emittedSalesNote,
      tableDeposit: tableDeposit ?? this.tableDeposit,
      resumedAttemptNotice: identical(resumedAttemptNotice, _noticeSentinel)
          ? this.resumedAttemptNotice
          : resumedAttemptNotice as String?,
    );
  }

  double get totalPaid => transactions.fold(0.0, (sum, t) => sum + t.amount);

  /// Saldo de mesa que este cobro ya tiene apartado en transacciones.
  double get depositApplied => transactions
      .where((t) => t.method == PaymentMethodType.tableDeposit)
      .fold(0.0, (sum, t) => sum + t.amount);

  /// Saldo que todavía se puede aplicar: lo que la mesa tiene menos lo que
  /// este mismo cobro ya apartó.
  double get depositAvailable {
    final balance = tableDeposit?.balance ?? 0;
    final left = balance - depositApplied;
    return left > 0 ? left : 0;
  }

  /// La mesa tiene saldo que ofrecer en este cobro.
  bool get hasTableDeposit => depositAvailable > 0.005;

  /// El saldo no alcanza para toda la cuenta: el cliente paga la diferencia
  /// con otro método. Es el caso "consumió 9,500 y tenía 9,000".
  double get depositShortfall {
    if ((tableDeposit?.balance ?? 0) <= 0) return 0;
    final diff = totalAmount - (tableDeposit?.balance ?? 0);
    return diff > 0.005 ? diff : 0;
  }

  double get remaining =>
      (totalAmount - totalPaid) > 0 ? (totalAmount - totalPaid) : 0;
  double get change =>
      (totalPaid - totalAmount) > 0 ? (totalPaid - totalAmount) : 0;
  double get inputAmount => double.tryParse(currentInput) ?? 0;
  bool get isComplete => remaining <= 0.01; // Tolerance

  /// El cobro esta en vuelo, o cerrando con el estado final a la vista.
  ///
  /// Incluye `stage != idle` a proposito: durante el segundo y pico que dura
  /// "Facturado" tanto `isProcessing` como `isPrinting` ya estan en false, y
  /// sin esto el boton se volveria a habilitar justo antes de que el modal se
  /// cierre — una ventana chica pero suficiente para cobrar dos veces.
  bool get isBusy => isProcessing || isPrinting || stage != PaymentStage.idle;
}

// ==============================================================================
// 🧠 VIEW MODEL
// ==============================================================================

class _PaymentIntentPersistenceException implements Exception {
  const _PaymentIntentPersistenceException({
    required this.hasConfirmedPayments,
  });

  final bool hasConfirmedPayments;
}

class PaymentSplitViewModel extends StateNotifier<PaymentSplitState> {
  final SalesRepositoryImproved _salesRepo;
  final ConnectivityService _connectivity = ConnectivityService();
  final OfflinePosService _offlinePos = OfflinePosService();

  final String _orderId;
  final String? _checkId;
  final String? _customerId;
  final String? _customerRnc;
  final String? _fiscalType;
  final String? _cashierSessionId;
  final Ref _ref;
  final Future<String?> Function({bool skipLocal})? _sessionResolver;
  final Future<String?> Function()? _businessResolver;
  final Future<void> Function({
    required String businessId,
    required Map<String, dynamic> action,
  })?
  _enqueuePayment;
  final bool Function()? _connectionStatus;
  SalesNotePolicy _salesNotePolicy;

  bool get _isConnected =>
      _connectionStatus?.call() ?? _connectivity.isConnected;

  /// Guard sincronico antes de cualquier `await` para bloquear
  /// double-tap / re-fire en el mismo frame. `state.isProcessing` es
  /// equivalente conceptualmente, pero el rebuild que lo expone al boton
  /// llega en el siguiente frame y deja una ventana de race minima.
  /// Este flag es field privado: las dos invocaciones lo ven sincrono.
  bool _localProcessing = false;
  bool _attemptLocked = false;
  bool _paymentConfirmed = false;
  bool _offlineAttempt = false;
  final Map<int, Payment> _recordedPayments = {};
  // No final: al recuperar un cobro interrumpido se retoma SU id, del que
  // salen los ids de la cola offline (`payment-<attemptId>-<índice>`).
  String _attemptId = const Uuid().v4();
  DateTime? _attemptPaidAt;
  bool _offlineNcfResolved = false;
  String? _attemptOfflineNcf;

  /// Diario durable del intento (ver [PaymentIntentJournal]).
  final PaymentIntentJournal _intentJournal;

  /// Lectura del diario al abrir el modal. `confirmPayment` la espera la
  /// primera vez para no arrancar un cobro nuevo encima de uno interrumpido.
  Future<void>? _intentRestore;
  Future<void>? _salesNotePolicyLoad;

  /// Intento interrumpido encontrado cuando el cajero ya había empezado a
  /// armar otro plan: se aplica al confirmar en vez de cobrar el plan nuevo.
  PaymentIntent? _pendingIntent;

  /// Lo último guardado en el diario para este intento.
  PaymentIntent? _journalIntent;

  /// El intento vino del diario (cobro interrumpido): su plan no se toca.
  bool _resumedFromJournal = false;

  // --- Candado de cobro por cuenta (20260929_0002) ---
  /// `split_sequence` del abono 0: el primero libre según el servidor, para no
  /// chocar con abonos de un cobro anterior. Fijo durante todo el intento.
  int _splitSequenceBase = 0;
  bool _splitSequenceBaseFixed = false;

  /// Lo que otro intento ya había cobrado en esta cuenta y este intento ya
  /// descontó del total (cobro anterior a medias).
  double _paidBeforeAttempt = 0;

  // `_localProcessing` también bloquea: la primera confirmación espera la
  // lectura del diario antes de marcar `isProcessing`, y en esa ventana el
  // plan ya no se puede cambiar.
  bool get _canEdit =>
      !_localProcessing &&
      !state.isBusy &&
      !_attemptLocked &&
      !_paymentConfirmed;

  PaymentSplitViewModel(
    this._salesRepo,
    this._orderId,
    double total, {
    String? checkId,
    String? customerId,
    String? customerRnc,
    String? fiscalType,
    String? cashierSessionId,
    required Ref ref,
    bool initialize = true,
    Future<String?> Function({bool skipLocal})? sessionResolver,
    Future<String?> Function()? businessResolver,
    Future<void> Function({
      required String businessId,
      required Map<String, dynamic> action,
    })?
    enqueuePayment,
    bool Function()? connectionStatus,
    SalesNotePolicy? salesNotePolicy,
    PaymentIntentJournal intentJournal = const PaymentIntentJournal(),
  }) : _salesNotePolicy =
           salesNotePolicy ?? const SalesNotePolicy(enabled: false),
       _intentJournal = intentJournal,
       _checkId = checkId,
       _customerId = customerId,
       _customerRnc = customerRnc,
       _fiscalType = fiscalType,
       _cashierSessionId = cashierSessionId,
       _ref = ref,
       _sessionResolver = sessionResolver,
       _businessResolver = businessResolver,
       _enqueuePayment = enqueuePayment,
       _connectionStatus = connectionStatus,
       super(PaymentSplitState(totalAmount: total)) {
    if (initialize) {
      unawaited(_connectivity.initialize());
      _loadOrderForReceipt();
      _loadTableDeposit();
      _salesNotePolicyLoad = _loadSalesNotePolicy();
    }
    // Cortesía 100%: cuando total == 0 no hay nada que cobrar, pero el
    // flujo de cierre necesita pasar por processPayment para generar
    // fiscal_document y cerrar orden/check. Pre-seedeamos una transacción
    // efectivo $0 para que canConfirm habilite directo y el cajero solo
    // confirme. Ver removeTransaction (no permite borrar la última en
    // este caso) y bug-fix histórico del botón "Pagar RD$ 0.00" bloqueado.
    if (total <= 0.01) {
      state = state.copyWith(
        transactions: [
          PaymentTransaction(
            id: const Uuid().v4(),
            method: PaymentMethodType.cash,
            amount: 0,
            timestamp: DateTime.now(),
          ),
        ],
      );
    }
    _applySalesNotePolicy(resetSelection: true);
    _intentRestore = _restoreInterruptedIntent();
  }

  // --- DIARIO DURABLE DEL INTENTO ---

  /// Busca un cobro de ESTA cuenta que quedó a medias (la app se cerró o se
  /// reinició durante el cobro) y lo retoma tal cual. Nunca lanza.
  Future<void> _restoreInterruptedIntent() async {
    final intent = await _intentJournal.load(_orderId, _checkId);
    if (intent == null || !mounted) return;
    final untouched =
        !_attemptLocked &&
        !_paymentConfirmed &&
        state.transactions.every((t) => t.amount.abs() < 0.001);
    if (untouched) {
      _applyIntent(intent);
    } else {
      _pendingIntent = intent;
    }
  }

  void _applyIntent(PaymentIntent intent) {
    _pendingIntent = null;
    final registered = intent.recordedPayments.length;
    final planTotal = intent.lines.fold<double>(0, (s, l) => s + l.amount);
    // El intento pudo cobrar solo el restante de un cobro anterior: el total
    // de la cuenta es lo de ese intento más lo que ya estaba cobrado.
    if ((intent.totalAmount + intent.paidBeforeAttempt - state.totalAmount)
            .abs() >
        0.01) {
      // La cuenta cambió desde el cobro interrumpido: retomarlo cobraría otro
      // monto. Solo se avisa; el cajero decide con el historial de pagos.
      state = state.copyWith(
        resumedAttemptNotice:
            'Hay un cobro que quedó a medias en esta cuenta por '
            '${intent.totalAmount.toStringAsFixed(2)} '
            '($registered de ${intent.lines.length} pagos ya registrados). '
            'La cuenta ahora suma ${state.totalAmount.toStringAsFixed(2)}. '
            'Revisa el historial de pagos antes de cobrar.',
      );
      return;
    }
    _attemptId = intent.attemptId;
    _attemptPaidAt = intent.paidAt;
    _attemptOfflineNcf = intent.offlineNcf;
    _offlineNcfResolved = intent.offlineNcfResolved;
    _offlineAttempt = intent.offline;
    _recordedPayments
      ..clear()
      ..addAll(intent.recordedPayments);
    _attemptLocked = true;
    _journalIntent = intent;
    _resumedFromJournal = true;
    _splitSequenceBase = intent.splitSequenceBase;
    _splitSequenceBaseFixed = true;
    _paidBeforeAttempt = intent.paidBeforeAttempt;
    state = state.copyWith(
      totalAmount: intent.totalAmount,
      transactions: [
        for (final line in intent.lines)
          PaymentTransaction(
            id: const Uuid().v4(),
            method: PaymentMethodType.values.firstWhere(
              (m) => m.name == line.method,
              orElse: () => PaymentMethodType.other,
            ),
            amount: line.amount,
            timestamp: intent.paidAt.toLocal(),
            reference: line.reference,
            bankAccount: line.bankAccount,
          ),
      ],
      salesNoteSelected: intent.salesNoteSelected,
      offlineNcf: intent.offlineNcf,
      currentInput: '',
      resumedAttemptNotice:
          'Se recuperó un cobro que quedó a medias: '
          '${intent.lines.length} pagos por ${planTotal.toStringAsFixed(2)} '
          '($registered ya registrados). Confirma para terminar ESTE mismo '
          'cobro; no se puede cambiar.',
    );
  }

  PaymentIntent _buildIntent() => PaymentIntent(
    attemptId: _attemptId,
    orderId: _orderId,
    checkId: _checkId,
    businessId: _activeBusinessIdOrNull(),
    totalAmount: state.totalAmount,
    lines: [
      for (final tx in state.transactions)
        PaymentIntentLine(
          method: tx.method.name,
          amount: tx.amount,
          reference: tx.reference,
          bankAccount: tx.bankAccount,
        ),
    ],
    paidAt: _attemptPaidAt ?? DateTime.now().toUtc(),
    createdAt: _journalIntent?.createdAt ?? DateTime.now().toUtc(),
    offline: _offlineAttempt,
    offlineNcf: _attemptOfflineNcf,
    offlineNcfResolved: _offlineNcfResolved,
    salesNoteSelected: state.salesNoteSelected,
    recordedPayments: Map<int, Payment>.from(_recordedPayments),
    splitSequenceBase: _splitSequenceBase,
    paidBeforeAttempt: _paidBeforeAttempt,
  );

  /// Solo para poder limpiar los intentos de un negocio; no es crítico. Se lee
  /// únicamente si la sesión ya está viva (en la app siempre lo está): leerla
  /// en frío la construiría solo para esto.
  String? _activeBusinessIdOrNull() {
    try {
      if (!_ref.exists(sessionProvider)) return null;
      return _ref.read(sessionProvider).activeBusinessId;
    } catch (_) {
      return null;
    }
  }

  /// Guarda el estado ACTUAL del intento. Falla abierto: sin disco el cobro
  /// sigue (mismo comportamiento que antes del diario), solo se registra.
  Future<void> _saveIntent() async {
    final intent = _buildIntent();
    if (!await _intentJournal.save(intent)) {
      throw _PaymentIntentPersistenceException(
        hasConfirmedPayments: _recordedPayments.isNotEmpty,
      );
    }
    _journalIntent = intent;
  }

  String? _holderLabelOrNull() {
    try {
      if (!_ref.exists(sessionProvider)) return null;
      final name = _ref.read(sessionProvider).userName?.trim();
      return (name == null || name.isEmpty) ? null : name;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _deviceIdOrNull() async {
    try {
      return await DeviceUtils.getDeviceId();
    } catch (_) {
      return null;
    }
  }

  /// Candado de cobro de la cuenta, compartido entre TODOS los equipos
  /// (20260929_0002). `true` = seguir; `false` = no cobrar (el estado ya dice
  /// por qué, y aquí no se grabó nada). Un error de red sube: el caller decide
  /// ir offline. Sin la migración aplicada sigue como antes.
  Future<bool> _acquirePaymentLock() async {
    PaymentAttemptLease? lease;
    try {
      lease = await _salesRepo.acquirePaymentAttempt(
        orderId: _orderId,
        checkId: _checkId,
        attemptId: _attemptId,
        deviceId: await _deviceIdOrNull(),
        holderLabel: _holderLabelOrNull(),
      );
    } catch (e) {
      if (OfflinePosService.isTransportError(e)) rethrow;
      state = state.copyWith(
        error:
            'No se pudo verificar el candado de esta cuenta. '
            'Aquí no se cobró nada. Detalle: $e',
      );
      return false;
    }
    if (lease == null) return false;

    if (!lease.acquired) {
      final holder = lease.holderLabel;
      state = state.copyWith(
        error: lease.accountClosed
            ? 'Esta cuenta ya fue cobrada. Refresca la mesa para ver el '
                  'comprobante.'
            : 'Otro equipo${holder == null ? '' : ' ($holder)'} está cobrando '
                  'esta cuenta en este momento. Espera a que termine: aquí no '
                  'se cobró nada.',
      );
      return false;
    }

    if (!_splitSequenceBaseFixed) {
      _splitSequenceBase = lease.nextSplitSequence;
      _splitSequenceBaseFixed = true;
    }

    // Cobros de OTRO intento en esta cuenta que este todavía no descontó.
    final newlyPaid = lease.paidByOthers - _paidBeforeAttempt;
    if (newlyPaid <= 0.009) return true;

    unawaited(
      _salesRepo.releasePaymentAttempt(
        orderId: _orderId,
        attemptId: _attemptId,
      ),
    );
    final paid = lease.paidByOthers.toStringAsFixed(2);
    if (_resumedFromJournal || _recordedPayments.isNotEmpty) {
      // Plan bloqueado (pudo haber cobrado ya): no se puede recortar a ciegas.
      state = state.copyWith(
        error:
            'Otro cobro registró $paid en esta cuenta mientras este cobro '
            'estaba pendiente. Revisa el historial de pagos antes de continuar.',
      );
      return false;
    }
    final remaining =
        state.totalAmount + _paidBeforeAttempt - lease.paidByOthers;
    if (remaining <= 0.01) {
      state = state.copyWith(
        error:
            'Esta cuenta ya tiene $paid cobrados de un cobro anterior que no '
            'terminó y no queda saldo. Revisa el historial de pagos.',
      );
      return false;
    }
    // Cobro anterior a medias (p. ej. en otra caja que se apagó): se cobra
    // SOLO el restante. Nada se grabó todavía en este intento.
    _paidBeforeAttempt = lease.paidByOthers;
    state = state.copyWith(
      totalAmount: remaining,
      transactions: const [],
      currentInput: '',
      resumedAttemptNotice:
          'Esta cuenta ya tiene $paid cobrados de un cobro anterior que no '
          'terminó. Se cobra solo el restante: ${remaining.toStringAsFixed(2)}. '
          'Carga el pago y confirma.',
    );
    return false;
  }

  Future<void> _finishIntent() async {
    _journalIntent = null;
    await _intentJournal.clear(_orderId, _checkId);
    state = state.copyWith(resumedAttemptNotice: null);
  }

  String _friendlyPaymentError(Object error) {
    final raw = error.toString();

    if (raw.contains('Demasiadas colisiones de NCF')) {
      return 'No se pudo emitir el comprobante fiscal de este negocio porque su numeracion entra en conflicto con una configuracion fiscal existente. Revisa Ajustes > Fiscal.';
    }

    if (raw.contains('No hay secuencia NCF disponible para tipo') ||
        raw.contains('Secuencia NCF agotada para tipo')) {
      return 'El negocio no tiene una secuencia fiscal activa para el tipo de comprobante seleccionado. Revisa Ajustes > Fiscal.';
    }

    if (raw.contains('ORDER_OUT_OF_SCOPE')) {
      return 'La orden ya no pertenece al negocio activo. Recarga la mesa e intenta de nuevo.';
    }

    if (raw.contains('ORDER_ALREADY_CLOSED') ||
        raw.contains('CHECK_ALREADY_CLOSED')) {
      return 'Esta cuenta ya fue cobrada. Refresca el historial para ver el comprobante.';
    }

    if (raw.contains('CASH_SESSION_REQUIRED') ||
        raw.contains('CASH_SESSION_NOT_OPEN')) {
      return 'Debes abrir una caja antes de procesar el cobro.';
    }

    if (raw.contains(SalesRepositoryImproved.paymentLockedCode)) {
      return 'Otro equipo está cobrando esta cuenta en este momento. Espera a '
          'que termine; este abono no se cobró.';
    }

    if (raw.startsWith('Exception: ')) {
      return raw.substring('Exception: '.length);
    }

    return raw;
  }

  /// Id de [session] solo si sigue abierta. Una sesión cerrada nunca sirve
  /// para cobrar: el RPC la rechaza con `CASH_SESSION_NOT_OPEN`.
  @visibleForTesting
  static String? openSessionIdOf(Map<String, dynamic>? session) {
    if (session == null) return null;
    if (session['status']?.toString() != 'open') return null;
    if (session['closed_at'] != null) return null;
    final id = session['id']?.toString();
    return (id == null || id.isEmpty) ? null : id;
  }

  @visibleForTesting
  static bool isCashSessionNotOpenError(Object error) =>
      error.toString().contains('CASH_SESSION_NOT_OPEN');

  /// Caja contra la que se cobra, resuelta AL CONFIRMAR.
  ///
  /// Antes se usaba el id que tenía la pantalla de Caja cuando se CREÓ este
  /// viewmodel, sin mirar si estaba abierta. El provider es una familia sin
  /// autoDispose (vive mientras la app esté abierta, por orden + monto), así
  /// que ese id quedaba congelado: si el modal de una mesa se abrió antes de
  /// abrir la caja, o antes de un cierre y reapertura, cada reintento mandaba
  /// la sesión vieja y el servidor contestaba "Debes abrir una caja" a la
  /// misma cajera que la acababa de abrir en ese mismo equipo.
  ///
  /// Orden: mi caja según la pantalla de Caja (leída ahora y solo si está
  /// abierta) → consulta al servidor. Con [skipLocal] va directo al servidor:
  /// es el reintento cuando el servidor dijo que la caja local ya se cerró.
  Future<String?> _resolveCashierSessionId({bool skipLocal = false}) async {
    if (_sessionResolver != null) return _sessionResolver(skipLocal: skipLocal);
    final cashier = _ref.read(cashierViewModelProvider);

    if (!skipLocal) {
      final live = openSessionIdOf(cashier.lastSession);
      if (live != null) return live;
    }

    // Sin red no hay a quién preguntar: se conserva el comportamiento de
    // siempre para que el cobro offline no cambie. En el reintento no: esa
    // caja ya la rechazó el servidor.
    final offlineFallback =
        (!skipLocal &&
            _cashierSessionId != null &&
            _cashierSessionId.isNotEmpty)
        ? _cashierSessionId
        : null;
    if (!_isConnected) return offlineFallback;

    try {
      return await _resolveOpenSessionFromServer(
        cashier,
      ).timeout(const Duration(seconds: 8));
    } catch (e) {
      if (OfflinePosService.isTransportError(e)) return offlineFallback;
      rethrow;
    }
  }

  /// Caja con la que puede cobrar ESTE equipo, preguntando al servidor. La
  /// caja es del equipo donde se abrió: cajero/mesero solo cobran con la de
  /// su equipo; dueño/admin con la suya, la de este equipo o la del negocio.
  /// Ver [CashierRepository.pickChargeSession].
  Future<String?> _resolveOpenSessionFromServer(
    CashierViewModel cashier,
  ) async {
    final repo = _ref.read(cashierRepositoryProvider);
    final businessId =
        _ref.read(sessionProvider).activeBusinessId ?? cashier.businessId;
    if (businessId == null || businessId.isEmpty) return null;

    String? deviceId;
    try {
      deviceId = await DeviceUtils.getDeviceId();
    } catch (_) {}

    final picked = CashierRepository.pickChargeSession(
      await repo.getOpenSessionsForBusiness(businessId),
      userId: Supabase.instance.client.auth.currentUser?.id,
      deviceId: deviceId,
      registerId: cashier.currentRegisterId,
      canOperateAnyDevice: _ref.read(sessionProvider).isOwnerOrAdmin,
    );
    return openSessionIdOf(picked);
  }

  Future<void> _loadOrderForReceipt() async {
    try {
      final businessId = _ref.read(sessionProvider).activeBusinessId;
      final order = await _salesRepo.getOrder(_orderId, businessId: businessId);
      final items = await _salesRepo.getOrderItems(
        _orderId,
        businessId: businessId,
      );
      state = state.copyWith(orderDetails: order, orderItems: items);
    } catch (e) {
      debugPrint('Error loading order details: $e');
    }
  }

  Future<void> _loadSalesNotePolicy() async {
    // Nota de venta: documento NO fiscal. El flag sale de las features del
    // negocio (con caché local, así que también resuelve offline). Fail-soft:
    // si no se puede leer, la opción no aparece y el cobro es el de siempre.
    try {
      final businessId = _ref.read(sessionProvider).activeBusinessId;
      if (businessId != null && businessId.isNotEmpty) {
        final features = await _ref
            .read(posSettingsRepositoryProvider)
            .getBusinessFeatures(businessId);
        if (!mounted) return;
        _salesNotePolicy = SalesNotePolicy(
          enabled: features.salesNoteEnabled,
          notesBeforeInvoice: features.salesNoteLimit,
          currentCount: features.salesNoteCount,
        );
        if (_canEdit) {
          _applySalesNotePolicy(resetSelection: true);
        }
      }
    } catch (_) {}
  }

  /// Saldo prepagado de la mesa de esta orden.
  ///
  /// Fail-soft: si el módulo no está instalado, no hay red o la venta no es de
  /// mesa, el saldo queda vacío y el cobro es exactamente el de siempre.
  Future<void> _loadTableDeposit() async {
    try {
      final account = await _ref
          .read(tableDepositRepositoryProvider)
          .getBalanceForOrder(_orderId);
      if (!mounted) return;
      state = state.copyWith(tableDeposit: account);
    } catch (e) {
      debugPrint('[abono] no se pudo leer el saldo de la mesa: $e');
    }
  }

  /// Alterna entre comprobante fiscal y NOTA DE VENTA para este cobro.
  void setSalesNote(bool value) {
    if (!_canEdit) return;
    if (value && !state.salesNoteAvailable) return;
    if (state.salesNoteSelected == value) return;
    state = state.copyWith(salesNoteSelected: value);
  }

  /// Lo fija el diálogo: corre en cuanto el servidor confirma el último
  /// abono, antes de la espera del e-CF (hasta ~8 s). La pantalla de ventas lo
  /// usa para la marca local de venta cobrada, con la orden, el origen y la
  /// sub-cuenta del cobro (no los de la pantalla, que pueden cambiar antes de
  /// que responda el servidor). Best-effort: un fallo no frena el cobro.
  Future<void> Function(List<Payment> payments)? onServerConfirmed;

  // El aviso va una sola vez por cobro: en el ciclo, o después si el último
  // abono ya venía confirmado.
  bool _serverConfirmedNotified = false;

  Future<void> _notifyServerConfirmed(List<Payment> payments) async {
    final hook = onServerConfirmed;
    if (hook == null || _serverConfirmedNotified) return;
    _serverConfirmedNotified = true;
    try {
      await hook(payments);
    } catch (e) {
      debugPrint('[split] onServerConfirmed: $e');
    }
  }

  String? get _effectiveFiscalType {
    if (_fiscalType != null && _fiscalType.trim().isNotEmpty) {
      return _fiscalType;
    }
    try {
      if (!_ref.exists(currentOrderProvider)) return null;
      return _ref.read(currentOrderProvider).fiscalType;
    } catch (_) {
      return null;
    }
  }

  /// Mientras falta saldo, el método activo también forma parte del plan.
  /// Al completarlo mandan los pagos cargados, aunque el selector conserve
  /// el método que se usó antes de completar el efectivo.
  Iterable<String> get _plannedMethodCodes sync* {
    for (final tx in state.transactions) {
      yield tx.method.name;
    }
    if (state.transactions.isEmpty || !state.isComplete) {
      yield state.activeMethod.name;
    }
  }

  void _applySalesNotePolicy({bool resetSelection = false}) {
    final available = _salesNotePolicy.allowsNote(
      fiscalType: _effectiveFiscalType,
      paymentMethodCodes: _plannedMethodCodes,
    );
    final selectByDefault = resetSelection || !state.salesNoteAvailable;
    state = state.copyWith(
      salesNoteAvailable: available,
      salesNoteSelected:
          available &&
          (selectByDefault
              ? _salesNotePolicy.shouldSelectNote(
                  fiscalType: _effectiveFiscalType,
                  paymentMethodCodes: _plannedMethodCodes,
                )
              : state.salesNoteSelected),
    );
  }

  /// Solo el efectivo de consumidor final participa en este ciclo.
  String? get salesNoteCycleMessage {
    final methods = _plannedMethodCodes.toList();
    final eligible =
        _salesNotePolicy.enabled &&
        SalesNotePolicy.isConsumerFinal(_effectiveFiscalType) &&
        methods.isNotEmpty &&
        methods.every((code) => code == 'cash');
    if (!eligible) return null;
    final count = _salesNotePolicy.currentCount;
    final limit = _salesNotePolicy.notesBeforeInvoice;
    if (!state.salesNoteAvailable) {
      return 'Se utilizaron $count de $limit notas de venta. '
          'Este cobro será factura.';
    }
    return 'Notas de venta: $count de $limit. Después, factura.';
  }

  /// True cuando la serie del comprobante es electronica (Exx / e-CF).
  ///
  /// La UI lo necesita ANTES de que exista el `fiscal_document` para saber si
  /// dibujar la etapa de DGII: en NCF de papel (B01/B02) el numero sale de la
  /// secuencia local y esa espera no ocurre, asi que listarla haria creer que
  /// el cobro tarda mas de lo que tarda.
  bool get isElectronicFiscal => isElectronicNcf(_effectiveFiscalType);

  /// Cierra el ciclo del cobro: apaga la impresion y deja el estado final a
  /// la vista. La pantalla lo sostiene un momento y despues cierra el modal.
  ///
  /// Va separado de `setPrinting(false)` porque son dos cosas distintas:
  /// "termine de imprimir y no paso nada mas" vs "el cobro cerro bien".
  void markFinished() {
    state = state.copyWith(isPrinting: false, stage: PaymentStage.listo);
  }

  /// Marca/desmarca la fase de impresion. La pantalla la usa para
  /// mantener el modal abierto mientras corre el callback de print, y
  /// para deshabilitar los botones de cerrar mientras tanto.
  void setPrinting(bool value) {
    if (state.isPrinting == value) return;
    state = state.copyWith(
      isPrinting: value,
      // A completed payment never becomes editable or chargeable again.
      stage: value
          ? PaymentStage.imprimiendo
          : (_paymentConfirmed ? PaymentStage.listo : PaymentStage.idle),
    );
  }

  // --- INPUT HANDLING ---

  void setInput(String val) {
    if (!_canEdit) return;
    state = state.copyWith(currentInput: val, validationError: null);
  }

  void appendInput(String char) {
    if (!_canEdit) return;
    if (char == '.' && state.currentInput.contains('.')) return;
    state = state.copyWith(
      currentInput: state.currentInput + char,
      validationError: null,
    );
  }

  void backspace() {
    if (!_canEdit) return;
    if (state.currentInput.isNotEmpty) {
      state = state.copyWith(
        currentInput: state.currentInput.substring(
          0,
          state.currentInput.length - 1,
        ),
        validationError: null,
      );
    }
  }

  void clearInput() {
    if (!_canEdit) return;
    state = state.copyWith(currentInput: '', validationError: null);
  }

  void setMethod(PaymentMethodType method, {bool presetRemaining = true}) {
    if (!_canEdit) return;
    state = state.copyWith(
      activeMethod: method,
      validationError: null,
      // Cambiar de método siempre limpia la cuenta bancaria seleccionada
      // (era válida solo para transferencia). Al volver a transfer, el
      // cajero tiene que volver a seleccionarla — UX explícita.
      selectedBankAccount: null,
    );
    _applySalesNotePolicy();
    // Saldo de mesa: se precarga con lo que el saldo ALCANCE a cubrir, no con
    // todo lo pendiente. Si la cuenta es 9,500 y la mesa tiene 9,000, el campo
    // arranca en 9,000 y el cajero solo tiene que cobrar los 500 de diferencia
    // con otro método.
    if (method == PaymentMethodType.tableDeposit) {
      final usable = state.depositAvailable < state.remaining
          ? state.depositAvailable
          : state.remaining;
      if (usable > 0) {
        state = state.copyWith(currentInput: usable.toStringAsFixed(2));
      }
      return;
    }

    // Prefill with remaining for convenience when no input is present.
    if (presetRemaining && (state.inputAmount == 0) && state.remaining > 0) {
      state = state.copyWith(currentInput: state.remaining.toStringAsFixed(2));
    }
  }

  /// Selector usado por el screen cuando el método activo es
  /// transferencia. El cajero elige a cuál cuenta del negocio llegó la
  /// transferencia; persistimos el id en `payments.bank_account_id` al
  /// confirmar el pago.
  void setBankAccount(BankAccount? account) {
    if (!_canEdit) return;
    if (!_ref
        .read(sessionProvider.notifier)
        .hasPermission('pagos.asignar_referencia')) {
      state = state.copyWith(
        validationError:
            'No tienes permiso para asignar la cuenta bancaria del cobro.',
      );
      return;
    }
    state = state.copyWith(selectedBankAccount: account, validationError: null);
  }

  void setQuickAmount(double amount) {
    if (!_canEdit) return;
    state = state.copyWith(
      currentInput: amount.toStringAsFixed(0),
      validationError: null,
    );
  }

  void setExactAmount() {
    if (!_canEdit) return;
    state = state.copyWith(
      currentInput: state.remaining.toStringAsFixed(2),
      validationError: null,
    );
  }

  // --- TRANSACTION MANAGEMENT (Split Logic) ---

  void addTransaction() {
    if (!_canEdit) return;
    final amount = state.inputAmount;
    if (!amount.isFinite || amount <= 0) {
      state = state.copyWith(validationError: 'Ingresa un monto mayor a cero.');
      return;
    }

    // Guarda dura: si ya se cubrió el total (con o sin cambio del último
    // payment), no se permiten más transacciones. Esto evita el caso
    // donde el cajero agrega de más sin querer y termina cobrando 600
    // sobre una orden de 500.
    if (state.remaining <= 0.01) {
      state = state.copyWith(
        validationError:
            'Ya se cubrió el total. Si necesitas modificar, elimina '
            'una transacción primero.',
      );
      return;
    }

    // Saldo de mesa: no puede pasar de lo que la mesa tiene. El trigger de BD
    // es el backstop (TABLE_DEPOSIT_INSUFFICIENT); acá damos el mensaje con el
    // número exacto para que el cajero sepa cuánto falta cobrar aparte.
    if (state.activeMethod == PaymentMethodType.tableDeposit) {
      if (!state.hasTableDeposit) {
        state = state.copyWith(
          validationError: 'Esta mesa no tiene saldo abonado disponible.',
        );
        return;
      }
      if (amount - state.depositAvailable > 0.01) {
        state = state.copyWith(
          validationError:
              'El saldo de la mesa es de RD\$ '
              '${state.depositAvailable.toStringAsFixed(2)}. Cobra esa parte '
              'con el saldo y la diferencia con otro método.',
        );
        return;
      }
      if (!_isConnected) {
        // El saldo se valida y se descuenta en el servidor. Si el cobro se
        // encola offline, al sincronizar podría no haber saldo (otra caja lo
        // consumió) y el pago quedaría rechazado con la mesa ya liberada.
        state = state.copyWith(
          validationError: 'El saldo de mesa no está disponible sin conexión.',
        );
        return;
      }
    }

    final allowsChange = state.activeMethod == PaymentMethodType.cash;
    final exceedsRemaining = amount - state.remaining > 0.01;
    if (exceedsRemaining && !allowsChange) {
      state = state.copyWith(
        validationError:
            'Tarjeta/transferencia no pueden exceder lo pendiente '
            '(RD\$ ${state.remaining.toStringAsFixed(2)}). Usa efectivo '
            'si el cliente quiere pagar con un monto mayor.',
      );
      return;
    }

    // Si es transferencia, el cajero tiene que haber seleccionado a cuál
    // cuenta del negocio llegó. Sin esto, perdemos trazabilidad.
    if (state.activeMethod == PaymentMethodType.transfer &&
        state.selectedBankAccount == null) {
      state = state.copyWith(
        validationError:
            'Selecciona la cuenta bancaria que recibió la transferencia.',
      );
      return;
    }

    final projectedRemaining = (state.remaining - amount).clamp(
      0.0,
      double.maxFinite,
    );

    final newTx = PaymentTransaction(
      id: const Uuid().v4(),
      method: state.activeMethod,
      amount: amount,
      timestamp: DateTime.now(),
      bankAccount: state.activeMethod == PaymentMethodType.transfer
          ? state.selectedBankAccount
          : null,
    );

    state = state.copyWith(
      transactions: [...state.transactions, newTx],
      currentInput: projectedRemaining > 0
          ? projectedRemaining.toStringAsFixed(2)
          : '',
      validationError: null,
      // Limpiamos la cuenta seleccionada para que el siguiente pago de
      // transferencia (si lo hay en el split) requiera elección explícita
      // — el cajero podría querer fragmentar entre varias cuentas.
      selectedBankAccount: null,
    );
    _applySalesNotePolicy();
  }

  void removeTransaction(String id) {
    if (!_canEdit) return;
    // Cortesía 100%: la transacción seed $0 (ver constructor) es la única
    // forma de cerrar la orden. No permitir borrarla; el cajero puede
    // cancelar el modal si no quiere cobrar.
    if (state.totalAmount <= 0.01 && state.transactions.length <= 1) return;
    final updated = state.transactions.where((t) => t.id != id).toList();
    final newRemaining =
        (state.totalAmount -
                updated.fold<double>(0, (sum, t) => sum + t.amount))
            .clamp(0.0, double.maxFinite);
    state = state.copyWith(
      transactions: updated,
      currentInput: newRemaining > 0 ? newRemaining.toStringAsFixed(2) : '',
      validationError: null,
    );
    _applySalesNotePolicy();
  }

  // --- CONFIRMATION & PRINTING ---

  /// Rama offline de [confirmPayment]: encola una acción `process_payment`
  /// por cada transacción con `paid_at = now() (UTC)` y devuelve una
  /// lista de [Payment] locales con `status='pending'`. Estos payments
  /// NO existen en server; el sync los crea cuando vuelve la red,
  /// preservando la fecha vía el parámetro `p_paid_at` del RPC.
  ///
  /// Retorna null si no se puede resolver el business_id (sin business
  /// no podemos encolar — el resolver es la única fuente de verdad para
  /// scopear la cola por negocio activo).
  Future<List<Payment>?> _confirmPaymentOffline({
    required String cashierSessionId,
  }) async {
    // El saldo de mesa NO viaja por la cola: se valida y se descuenta en el
    // servidor. Si se encolara, al sincronizar podría ya no haber saldo (otra
    // caja lo consumió) y el cobro quedaría rechazado con la mesa liberada y
    // el ticket entregado. Preferimos fallar acá, con la mesa todavía abierta.
    if (state.transactions.any(
      (t) => t.method == PaymentMethodType.tableDeposit,
    )) {
      state = state.copyWith(
        error:
            'El cobro con saldo de mesa necesita conexión. Vuelve a intentar '
            'cuando haya red, o cobra con otro método.',
      );
      return null;
    }

    try {
      final businessId =
          await (_businessResolver?.call() ??
              resolveBusinessIdOrNull(Supabase.instance.client, 'auto'));
      if (businessId == null || businessId.isEmpty) {
        throw StateError(
          'No se pudo identificar el negocio para guardar el cobro.',
        );
      }

      _attemptLocked = true;
      _offlineAttempt = true;
      final paidAtOffline = _attemptPaidAt ??= DateTime.now().toUtc();
      final paidAtIso = paidAtOffline.toIso8601String();
      // `_customerRnc` ya viene resuelto por sub-cuenta desde el call site
      // (RNC del cliente del check, con fallback al de la orden). Pasarlo
      // explícito es robusto aunque la función viva no herede del check.
      final customerRnc = _customerRnc;
      // `_fiscalType` ya viene resuelto por sub-cuenta desde el call site
      // (override del check si lo tiene). Solo caemos al tipo de la orden si
      // no se pasó ninguno, para no perder el comprobante por sub-cuenta en
      // el camino offline (la emisión online usa `_fiscalType` directo).
      final ncfType = (_fiscalType != null && _fiscalType.trim().isNotEmpty)
          ? _fiscalType
          : _ref.read(currentOrderProvider).fiscalType;

      // F4 (gated): un comprobante por cobro → asignamos el NCF UNA vez y lo
      // adjuntamos a la PRIMERA transacción. El trigger emite el fiscal_document
      // con ese número; las demás transacciones se enlazan por idempotencia.
      // Si no hay NCF (no papel / sin Hub / agotado) → recibo provisional.
      // Con NOTA DE VENTA no se pide número al Hub: quemaría un NCF del rango
      // autorizado para una venta que nunca va a declararse.
      if (!_offlineNcfResolved) {
        final allocated = state.salesNoteSelected
            ? null
            : await allocateOfflineNcfPaper(
                client: Supabase.instance.client,
                businessId: businessId,
                ncfType: ncfType,
                isConnected: () => ConnectivityService().isConnected,
              );
        _attemptOfflineNcf = allocated?.ncf;
        _offlineNcfResolved = true;
      }
      final offlineNcf = _attemptOfflineNcf;
      // El camino offline y el NCF de papel ya asignado van al diario: tras un
      // reinicio se retoma offline con ESE número (pedir otro al Hub dejaría
      // un hueco en la numeración fiscal).
      await _saveIntent();

      // Abonos de este intento que ya están en la cola (la app se cerró entre
      // encolar y anotar en el diario): no se encolan otra vez.
      final alreadyQueued = <String>{};
      if (_enqueuePayment == null) {
        try {
          for (final action in await _offlinePos.unsettledActions(businessId)) {
            final id = action['id']?.toString();
            if (id != null) alreadyQueued.add(id);
          }
        } catch (e) {
          debugPrint('[split-offline] no se pudo leer la cola: $e');
        }
      }

      final localPayments = <Payment>[];
      for (int i = 0; i < state.transactions.length; i++) {
        final recorded = _recordedPayments[i];
        if (recorded != null) {
          localPayments.add(recorded);
          continue;
        }
        final tx = state.transactions[i];
        final isLast = i == state.transactions.length - 1;
        final actionId = 'payment-$_attemptId-$i';

        String methodId;
        switch (tx.method) {
          case PaymentMethodType.cash:
            methodId = 'cash';
            break;
          case PaymentMethodType.card:
            methodId = 'card';
            break;
          case PaymentMethodType.transfer:
            methodId = 'transfer';
            break;
          default:
            methodId = 'cash';
        }

        if (!alreadyQueued.contains(actionId)) {
          await (_enqueuePayment ?? _offlinePos.enqueueAction)(
            businessId: businessId,
            action: {
              'id': actionId,
              'type': 'process_payment',
              'origin': _orderId.startsWith('local-order-')
                  ? 'offline'
                  : 'remote',
              'order_id': _orderId,
              'check_id': _checkId,
              'payment_method_id': methodId,
              'payment_method_code': methodId,
              'payment_method_name': tx.methodLabel,
              'amount': tx.amount,
              'reference': tx.reference,
              'customer_id': _customerId,
              'customer_rnc': isLast ? customerRnc : null,
              'cashier_session_id': cashierSessionId,
              'change_amount': isLast ? state.change : 0,
              // Base del intento: no choca con abonos de un cobro anterior.
              'split_sequence': _splitSequenceBase + i,
              'close_order': isLast && _checkId == null,
              'close_check': isLast && _checkId != null,
              'paid_at': paidAtIso,
              // F4: el NCF asignado offline viaja SOLO en la primera transacción
              // (un comprobante por cobro). El server lo usa al sincronizar.
              if (i == 0 && offlineNcf != null) 'offline_ncf': offlineNcf,
              'requested_ncf_type': ncfType,
              // NOTA DE VENTA: la marca viaja en la PRIMERA transacción para que
              // el replay la ponga antes de reproducir el cobro. Si llega
              // después, el cierre ya emitió NCF. Viaja el valor elegido
              // (incluido `false`) para que el replay no herede una marca vieja.
              if (i == 0 &&
                  (_salesNotePolicy.enabled || state.salesNoteSelected))
                'is_sales_note': state.salesNoteSelected,
              // Bank account se asocia post-RPC en el flujo online vía un
              // UPDATE puntual. Offline guardamos solo el id; el replay
              // queda pendiente de hacer ese UPDATE — para esta primera
              // versión el cajero re-asocia manualmente si hace falta.
              if (tx.bankAccount != null) 'bank_account_id': tx.bankAccount!.id,
            },
          );
        }

        localPayments.add(
          Payment(
            id: 'local-payment-${paidAtOffline.millisecondsSinceEpoch}-$i',
            businessId: businessId,
            orderId: _orderId,
            checkId: _checkId,
            paymentMethodId: methodId,
            paymentMethodCode: methodId,
            paymentMethodName: tx.methodLabel,
            amount: tx.amount,
            reference: tx.reference,
            changeAmount: isLast ? state.change : 0,
            status: 'pending',
            sessionId: cashierSessionId,
            createdAt: paidAtOffline.toLocal(),
            bankAccountId: tx.bankAccount?.id,
          ),
        );
        _recordedPayments[i] = localPayments.last;
        await _saveIntent();
      }
      // F4: dejamos el NCF en el estado para que el caller imprima el
      // comprobante con su número en el acto (en vez de la precuenta).
      if (offlineNcf != null) {
        state = state.copyWith(offlineNcf: offlineNcf);
      }
      // Todo el intento quedó en la cola durable (ids estables por índice):
      // el diario ya no hace falta.
      await _finishIntent();
      return localPayments;
    } catch (e, s) {
      debugPrint('❌ Error encolando pago offline: $e\n$s');
      state = state.copyWith(
        error:
            'No se pudo completar el guardado local del cobro. '
            'Reintenta sin cambiar los pagos. ${_friendlyPaymentError(e)}',
      );
      return null;
    }
  }

  Future<List<Payment>?> confirmPayment(BuildContext context) {
    return PerformanceDiagnostics.instance.measure(
      'confirmacion_pago_total',
      () => _confirmPaymentImpl(context),
      accepted: (payments) => payments != null && payments.isNotEmpty,
    );
  }

  Future<List<Payment>?> _confirmPaymentImpl(BuildContext context) async {
    if (_localProcessing || state.isBusy || _paymentConfirmed) return null;
    // Primera confirmación: esperar la lectura del diario (disco local, rápida)
    // con el guard puesto, para no arrancar un cobro NUEVO encima de uno que
    // quedó a medias. Si apareció mientras el cajero armaba otro plan, se
    // muestra el interrumpido y NO se cobra lo que estaba en pantalla.
    final restore = _intentRestore;
    final policyLoad = _salesNotePolicyLoad;
    if (restore != null || policyLoad != null) {
      _localProcessing = true;
      try {
        await restore;
        await policyLoad;
      } finally {
        _localProcessing = false;
        _intentRestore = null;
        _salesNotePolicyLoad = null;
      }
      final pending = _pendingIntent;
      if (pending != null) {
        _applyIntent(pending);
        return null;
      }
    }
    if (!_attemptLocked) _applySalesNotePolicy();
    if (state.transactions.isEmpty) {
      state = state.copyWith(
        validationError: 'Agrega al menos un pago antes de confirmar.',
      );
      return null;
    }

    if (!state.isComplete) {
      state = state.copyWith(
        validationError: 'Aún queda saldo pendiente por cobrar.',
      );
      return null;
    }

    // Guard sincronico: chequea el flag local ANTES de tocar `state`. Riverpod
    // expone `state.isProcessing` recien tras el rebuild del proximo frame, lo
    // que dejaba una ventana de race con doble-tap. El backend ya tiene guard
    // atomico (20260509_0001) que retorna el payment existente, pero esto
    // evita lanzar el RPC duplicado innecesariamente.
    _localProcessing = true;

    state = state.copyWith(
      isProcessing: true,
      stage: PaymentStage.registrando,
      // Cada cobro arranca su propio ciclo: ni el aviso de contingencia ni el
      // NCF del cobro anterior pueden arrastrarse al siguiente.
      dgiiContingency: false,
      emittedNcf: null,
      error: null,
      validationError: null,
    );

    final List<Payment> createdPayments = [];

    try {
      final resolvedSessionId = await _resolveCashierSessionId();
      if (resolvedSessionId == null || resolvedSessionId.isEmpty) {
        state = state.copyWith(
          isProcessing: false,
          stage: PaymentStage.idle,
          // Hay caja en el negocio pero no en este equipo: decir dónde
          // cobrar en vez de "no hay caja".
          validationError:
              _ref.read(cashierViewModelProvider).canSellWithOpenCash
              ? CashierRepository.cashOnOtherDeviceMessage
              : 'No hay una caja abierta para procesar el cobro.',
        );
        return null;
      }
      var cashierSessionId = resolvedSessionId;
      // Un solo reintento por cobro si el servidor dice que la caja que
      // teníamos en memoria ya no está abierta.
      var staleSessionRetried = false;

      // NOTA DE VENTA: la marca va ANTES del primer cobro. El documento lo
      // emite el trigger de cierre dentro del RPC de pago, así que ponerla
      // después llega tarde y la venta ya habría quemado un NCF. Si falla, se
      // aborta: consumir un comprobante fiscal no se deshace.
      //
      // Se escribe el valor ELEGIDO, no solo el `true`: un cobro anterior
      // marcado como nota y cancelado deja la marca puesta en la orden, y sin
      // este `false` explícito el siguiente cobro saldría como nota aunque el
      // cajero haya elegido factura. Solo corre en negocios con la feature
      // prendida.
      // Sin red se salta: la marca viaja en el payload de la cola, y esperar
      // a que esta escritura muriera retrasaba cada cobro offline.
      var useOffline =
          _offlineAttempt ||
          !_isConnected ||
          _orderId.startsWith('local-order-');
      if (useOffline && !_offlineAttempt && _recordedPayments.isNotEmpty) {
        throw StateError(
          'Hay abonos registrados en el servidor. '
          'Recupera la conexion para completar este cobro.',
        );
      }
      if ((_salesNotePolicy.enabled || state.salesNoteSelected) &&
          !useOffline) {
        try {
          await _salesRepo
              .markAsSalesNote(
                orderId: _orderId,
                checkId: _checkId,
                value: state.salesNoteSelected,
              )
              .timeout(const Duration(seconds: 8));
        } catch (e) {
          if (!OfflinePosService.isTransportError(e)) {
            _localProcessing = false;
            state = state.copyWith(
              isProcessing: false,
              stage: PaymentStage.idle,
              error:
                  'No se pudo preparar la nota de venta: '
                  '${_friendlyPaymentError(e)} El cobro no se procesó.',
            );
            return null;
          }
          // Error de transporte: sigue al camino offline, donde la marca
          // viaja en el payload de la cola.
          if (_recordedPayments.isNotEmpty && !_offlineAttempt) rethrow;
          useOffline = true;
        }
      }

      // NO consolidamos transactions: si el cajero agrega cash 1000 tres
      // veces (caso: tres clientes pagando 1000 cada uno), cada entrada se
      // persiste como un row independiente. El `split_sequence` distingue
      // intencionales (índice creciente) de doble-tap (mismo índice → 23505
      // recovered). Ver migration 20260510_0004.
      debugPrint(
        '💰 Confirming Payment: ${state.transactions.length} transactions',
      );

      // Check de conectividad ANTES del loop. Si no hay red, tomamos la
      // rama offline completa: encolamos cada transacción con paid_at y
      // construimos payments locales con status='pending'. Una vez en
      // sync, el RPC fn_process_payment_v3 los replayará preservando la
      // fecha (ver 20260522_0003_paid_at_offline_sync.sql).
      //
      // Candado de la cuenta entre equipos, antes de grabar nada. Si no hay
      // red para tomarlo y este intento todavía no grabó nada, se cobra
      // offline como cualquier otro corte.
      if (!useOffline) {
        bool proceed;
        try {
          proceed = await _acquirePaymentLock();
        } catch (e) {
          if (!OfflinePosService.isTransportError(e) ||
              _recordedPayments.isNotEmpty) {
            rethrow;
          }
          useOffline = true;
          proceed = true;
        }
        if (!proceed) {
          state = state.copyWith(
            isProcessing: false,
            stage: PaymentStage.idle,
            error: state.error,
          );
          return null;
        }
      }

      // Diario ANTES del primer envío: desde aquí el resultado puede quedar
      // incierto, así que el plan (y su fecha) tiene que sobrevivir a un
      // cierre de la app para retomarse con los mismos índices.
      _attemptPaidAt ??= DateTime.now().toUtc();
      await _saveIntent();
      if (useOffline) {
        final offlineResult = await _confirmPaymentOffline(
          cashierSessionId: cashierSessionId,
        );
        if (offlineResult != null) {
          _paymentConfirmed = true;
          createdPayments.addAll(offlineResult);
          state = state.copyWith(
            isProcessing: false,
            // Offline no consulta a la DGII: el NCF se emite al sincronizar.
            // Saltamos directo a imprimir (precuenta o comprobante con NCF
            // offline, según lo resuelva el caller).
            stage: PaymentStage.imprimiendo,
            isPrinting: true,
            offlineQueued: true,
          );
          return createdPayments;
        }
        state = state.copyWith(isProcessing: false, stage: PaymentStage.idle);
        return null;
      }

      // 1. Process all transactions
      for (int i = 0; i < state.transactions.length; i++) {
        final recorded = _recordedPayments[i];
        if (recorded != null) {
          createdPayments.add(recorded);
          continue;
        }
        final tx = state.transactions[i];
        final isLast = i == state.transactions.length - 1;

        // Map enum to ID
        String methodId;
        switch (tx.method) {
          case PaymentMethodType.cash:
            methodId = 'cash';
            break;
          case PaymentMethodType.card:
            methodId = 'card';
            break;
          case PaymentMethodType.transfer:
            methodId = 'transfer';
            break;
          case PaymentMethodType.tableDeposit:
            methodId = TableDepositRepository.methodCode;
            break;
          default:
            methodId = 'cash';
        }

        debugPrint(
          'Processing Tx $i: method=$methodId, amount=${tx.amount}, checkId=$_checkId',
        );

        Future<Payment> payWith(String sessionId) => _salesRepo.processPayment(
          orderId: _orderId,
          checkId: _checkId,
          paymentMethodId: methodId,
          amount: tx.amount,
          // El saldo de mesa nunca da vuelto (el trigger lo rechaza): el
          // vuelto sale del efectivo, no del prepago.
          changeAmount: isLast && tx.method != PaymentMethodType.tableDeposit
              ? state.change
              : 0,
          closeOrder: isLast && _checkId == null,
          // Para split methods dentro de un check: solo cerrar el
          // check en la última transacción. Las intermedias dejan el
          // check abierto para que las siguientes puedan insertarse
          // sin chocar contra "CHECK_ALREADY_CLOSED".
          closeCheck: isLast && _checkId != null,
          customerId: _customerId,
          // RNC resuelto por sub-cuenta (o de la orden) desde el call site.
          // Solo aplica en la última transacción (la que emite el NCF).
          customerRnc: isLast ? _customerRnc : null,
          // El servidor conserva el tipo consumidor final incluso si otra
          // caja consume la última nota disponible y este cobro debe facturar.
          fiscalType: _effectiveFiscalType,
          cashierSessionId: sessionId,
          reference: tx.reference,
          splitSequence: _splitSequenceBase + i,
          paidAt: _attemptPaidAt,
          attemptId: _attemptId,
        );

        Payment payment;
        // Once a write starts its outcome may be uncertain. Retries must keep
        // the same methods, amounts and split indices, including after errors.
        _attemptLocked = true;
        _attemptPaidAt ??= DateTime.now().toUtc();
        try {
          payment = await payWith(cashierSessionId);
        } catch (e) {
          debugPrint('❌ Error in processPayment: $e');

          // La caja que teníamos en memoria ya no está abierta (se cerró en
          // otro equipo, o quedó vieja de antes de una reapertura). El RPC
          // valida la caja antes de grabar nada, así que reintentar con la
          // caja que está abierta AHORA no duplica el cobro.
          String? freshSessionId;
          if (!staleSessionRetried && isCashSessionNotOpenError(e)) {
            staleSessionRetried = true;
            try {
              freshSessionId = await _resolveCashierSessionId(skipLocal: true);
            } catch (resolveError) {
              debugPrint(
                '[split] no se pudo re-resolver la caja: $resolveError',
              );
            }
          }

          if (freshSessionId != null && freshSessionId != cashierSessionId) {
            debugPrint(
              '[split] caja $cashierSessionId cerrada; reintento con '
              '$freshSessionId',
            );
            cashierSessionId = freshSessionId;
            // La pantalla de Caja también tenía la caja vieja.
            unawaited(_ref.read(cashierViewModelProvider).refreshSilently());
            payment = await payWith(freshSessionId);
          } else {
            // Fallback offline solo si la PRIMERA tx falla por red. Si ya
            // pasamos transacciones a server (i>0), una mezcla online/
            // offline sobre la misma orden genera estados inconsistentes
            // (pagos parciales aplicados, otros encolados) que el RPC no
            // sabe reconciliar — preferimos fallar limpio y que el cajero
            // reintente cuando vuelva la red.
            // Amplía Socket/Timeout a todo error de transporte (ClientException,
            // handshake, connection reset/closed) — común en redes malas. Solo
            // dispara el fallback offline en la PRIMERA tx (i==0), sin mezclar
            // online/offline sobre la misma orden.
            final isConnectivityError = OfflinePosService.isTransportError(e);
            if (i == 0 && isConnectivityError) {
              debugPrint(
                '[split-offline] tx#0 falló por red, fallback offline',
              );
              final offlineResult = await _confirmPaymentOffline(
                cashierSessionId: cashierSessionId,
              );
              if (offlineResult != null) {
                _paymentConfirmed = true;
                createdPayments
                  ..clear()
                  ..addAll(offlineResult);
                state = state.copyWith(
                  isProcessing: false,
                  stage: PaymentStage.imprimiendo,
                  isPrinting: true,
                  offlineQueued: true,
                );
                return createdPayments;
              }
            }
            rethrow;
          }
        }

        debugPrint('✅ Payment Processed: ${payment.id}');

        // Si la transacción tiene cuenta bancaria asociada, asociarla
        // al payment recién creado vía UPDATE puntual. No tocamos el
        // RPC fiscal (zona sensible) — un round-trip extra es OK.
        // Si el UPDATE falla, log y continuar; el cobro ya está hecho.
        var enrichedPayment = payment.copyWith(
          paymentMethodCode: methodId,
          paymentMethodName: tx.methodLabel,
        );
        _recordedPayments[i] = enrichedPayment;
        // Abono confirmado por el servidor: al diario ya, antes de cualquier
        // otra espera (cuenta bancaria, e-CF, impresión). El último cerró la
        // venta en el servidor: se avisa enseguida, aunque el diario falle
        // (la marca local de venta cobrada no espera al e-CF).
        try {
          await _saveIntent();
        } finally {
          if (isLast) {
            await _notifyServerConfirmed([
              ...createdPayments,
              enrichedPayment,
            ]);
          }
        }
        final bankAccount = tx.bankAccount;
        if (bankAccount != null) {
          try {
            await Supabase.instance.client
                .from('payments')
                .update({'bank_account_id': bankAccount.id})
                .eq('id', payment.id)
                .timeout(const Duration(seconds: 3));
            enrichedPayment = enrichedPayment.copyWith(
              bankAccountId: bankAccount.id,
            );
          } catch (e) {
            debugPrint(
              'No se pudo asociar bank_account a payment ${payment.id}: $e',
            );
          }
        }
        createdPayments.add(enrichedPayment);
        _recordedPayments[i] = enrichedPayment;
      }
      _paymentConfirmed = true;
      if (createdPayments.isNotEmpty) {
        unawaited(
          mirrorConfirmedPaymentToHub(
            ref: _ref,
            businessId: createdPayments.last.businessId,
            orderId: _orderId,
            paymentId: createdPayments.last.id,
            checkId: _checkId,
          ),
        );
      }
      // Todos los abonos confirmados: ya no hay nada que retomar.
      await _finishIntent();
      // Reintento cuyo último abono ya venía confirmado (p. ej. tras reiniciar
      // la app): no pasó por el aviso del ciclo.
      await _notifyServerConfirmed(createdPayments);
      // La cuenta principal puede normalizarse a `null` en el servidor. Los
      // documentos se buscan por el contenedor que realmente quedó cobrado.
      final documentCheckId = createdPayments.last.checkId;
      final documentId = createdPayments.last.fiscalDocumentId;

      // Para e-CF (Norma DGII 01-2020): invocamos emit-document SYNC despues
      // del processPayment para que cuando el caller imprima el ticket, el
      // fiscal_document ya este en estado 'sent' con security_code y el QR
      // pueda renderizarse. Sin esto, el ticket sale "Pendiente de emision a
      // DGII" porque processPayment crea el doc en 'pending' y nadie lo
      // procesa hasta que el cron de respaldo corra (~60s).
      //
      // Mismo comportamiento que payment_viewmodel.dart::_emitDocumentSync,
      // pero inline aqui porque este viewmodel tiene su propio flujo de
      // confirmPayment para cobros con split de pagos.
      // NOTA DE VENTA: no hay fiscal_document ni DGII a la que esperar. Se lee
      // la nota que emitió el trigger para mostrar su número en el estado
      // final, igual que se muestra el NCF.
      if (state.salesNoteSelected) {
        try {
          var noteQuery = Supabase.instance.client
              .from('sales_notes')
              .select('note_number')
              .eq('order_id', _orderId)
              .eq('status', 'active');
          noteQuery = (documentCheckId != null && documentCheckId.isNotEmpty)
              ? noteQuery.eq('check_id', documentCheckId)
              : noteQuery.isFilter('check_id', null);
          final noteRow = await noteQuery
              .order('created_at', ascending: false)
              .limit(1)
              .maybeSingle()
              .timeout(const Duration(seconds: 3));
          final number = noteRow?['note_number'] as String?;
          if (number != null && number.trim().isNotEmpty) {
            state = state.copyWith(emittedSalesNote: number.trim());
          }
        } catch (e) {
          // Fail-soft: el cobro ya cerró y el ticket se imprime con el número
          // que lee el caller; esto solo alimenta el estado final del modal.
          debugPrint('No se pudo leer la nota de venta emitida: $e');
        }
      }

      try {
        // Otra caja pudo agotar el cupo entre abrir este modal y cerrar el
        // cobro. El documento realmente emitido manda sobre la selección.
        var query = Supabase.instance.client
            .from('fiscal_documents')
            .select('id, is_electronic, ncf_number')
            .eq('status', 'active');
        if (documentId != null && documentId.isNotEmpty) {
          query = query.eq('id', documentId);
        } else {
          query = query.eq('order_id', _orderId);
          query = documentCheckId != null && documentCheckId.isNotEmpty
              ? query.eq('check_id', documentCheckId)
              : query.isFilter('check_id', null);
        }
        final fiscalDocRow = await query
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle()
            .timeout(const Duration(seconds: 3));
        if (fiscalDocRow != null) {
          state = state.copyWith(salesNoteSelected: false);
        }

        final ncf = fiscalDocRow?['ncf_number'] as String?;
        if (ncf != null && ncf.trim().isNotEmpty) {
          state = state.copyWith(emittedNcf: ncf.trim());
        }

        if (fiscalDocRow != null && fiscalDocRow['is_electronic'] == true) {
          final fiscalId = fiscalDocRow['id'] as String;
          // Solo aqui anunciamos la DGII: en NCF de papel (B01/B02) esta
          // espera no existe y mostrar la etapa seria mentirle al cajero
          // sobre cuanto falta.
          state = state.copyWith(stage: PaymentStage.dgii);
          final t0 = DateTime.now();
          debugPrint('[split-emit-sync] START doc=$fiscalId');
          try {
            final res = await Supabase.instance.client.functions
                .invoke('emit-document', body: {'fiscal_document_id': fiscalId})
                .timeout(const Duration(seconds: 8));
            final dt = DateTime.now().difference(t0).inMilliseconds;
            debugPrint('[split-emit-sync] OK status=${res.status} dt=${dt}ms');
          } on TimeoutException {
            final dt = DateTime.now().difference(t0).inMilliseconds;
            debugPrint('[split-emit-sync] TIMEOUT despues de ${dt}ms');
            // Contingencia, no error: el cobro ya esta grabado y el ticket
            // se imprime igual. El cron de respaldo y el webhook reenvian
            // el documento. Lo marcamos para que el overlay lo diga en vez
            // de dejar al cajero creyendo que la factura ya llego a DGII.
            state = state.copyWith(dgiiContingency: true);
          } catch (e) {
            debugPrint('[split-emit-sync] ERROR exception=$e');
            state = state.copyWith(dgiiContingency: true);
          }
        } else {
          debugPrint(
            '[split-emit-sync] doc no electronico o no encontrado, skip',
          );
        }
      } catch (e) {
        debugPrint('[split-emit-sync] fetch fiscal_doc fallo: $e');
      }

      // Si se pagó un check parcial, limpiar también en backend y local
      // OPTIMIZACIÓN: processPayment ya debe manejar el cierre del check y orden si aplica.
      if (_checkId != null) {
        debugPrint('Removing check locally: $_checkId');
        _ref.read(currentOrderProvider.notifier).removeCheckLocally(_checkId);
        _ref.read(currentOrderProvider.notifier).refreshOrder();
      }

      // 2. Print Receipt via QZ Tray (Agent) - DISABLED for speed
      // await _printReceipt();

      // Bridge atomico: pasamos directamente de "Procesando..." a
      // "Imprimiendo..." sin un frame intermedio donde isProcessing y
      // isPrinting esten ambos en false. Sin esto, el boton parpadea
      // un instante mostrando "Confirmar pago" entre el final del
      // RPC y el setPrinting(true) que hace _finishWithPayments en la
      // pantalla. La pantalla igual lo deja en false en el finally.
      state = state.copyWith(
        isProcessing: false,
        stage: PaymentStage.imprimiendo,
        isPrinting: true,
      );
      return createdPayments;
    } catch (e, stack) {
      debugPrint('❌ Fatal Error in confirmPayment: $e\n$stack');
      if (e is _PaymentIntentPersistenceException) {
        state = state.copyWith(
          isProcessing: false,
          stage: PaymentStage.idle,
          error: e.hasConfirmedPayments
              ? 'Hay pagos registrados, pero no se pudo guardar su progreso. '
                    'No cobres de nuevo: revisa el historial y libera espacio '
                    'o repara el almacenamiento antes de continuar.'
              : 'No se pudo guardar el intento de cobro en este equipo. '
                    'No se envió ningún pago. Revisa el almacenamiento e '
                    'intenta otra vez.',
        );
        return null;
      }
      if (_paymentConfirmed) {
        state = state.copyWith(
          isProcessing: false,
          isPrinting: true,
          stage: PaymentStage.imprimiendo,
        );
        return createdPayments;
      }
      state = state.copyWith(
        isProcessing: false,
        stage: PaymentStage.idle,
        error: _attemptLocked
            ? '${_friendlyPaymentError(e)} Reintenta este mismo cobro; '
                  'los pagos ya confirmados se conservan.'
            : _friendlyPaymentError(e),
      );
      return null;
    } finally {
      _localProcessing = false;
    }
  }

  /*
  Future<void> _printReceipt() async {
    try {
      // Basic Receipt Generation using ESC/POS
      // Print logic omitted for brevity
      // await _printingRepo.getPrinter('default'); ...
      // ...
    } catch (e) {
      debugPrint('Receipt printing error: $e');
    }
  }
  */
}

final paymentSplitProvider =
    StateNotifierProvider.family<
      PaymentSplitViewModel,
      PaymentSplitState,
      (String, double, String?, String?, String?, String?)
    >((ref, params) {
      final salesRepo = SalesRepositoryImproved(Supabase.instance.client);

      final cashierVM = ref.read(cashierViewModelProvider);
      final sessionId = cashierVM.lastSession?['id'] as String?;

      return PaymentSplitViewModel(
        salesRepo,
        params.$1, // orderId
        params.$2, // amount
        checkId: params.$3, // checkId
        customerId: params.$4, // customerId
        fiscalType: params.$5, // fiscalType
        customerRnc: params.$6, // customerRnc
        cashierSessionId: sessionId,
        ref: ref,
      );
    });
