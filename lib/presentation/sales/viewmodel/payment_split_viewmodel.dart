import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/bank_account.dart';
import '../../../data/models/sales_models.dart';

import '../../../data/repositories/sales_repository_improved.dart';
import '../../cashier/viewmodel/cashier_viewmodel.dart';
import '../viewmodel/sales_viewmodel.dart';
import '../../../services/session/session_controller.dart';

// ==============================================================================
// 📦 MODELS
// ==============================================================================

enum PaymentMethodType { cash, card, transfer, other }

/// Sentinel para diferenciar "no se pasó argumento" de "se pasó null
/// explícito" en `PaymentSplitState.copyWith` (sin esto no podríamos
/// limpiar `selectedBankAccount` al cambiar de método de pago).
const Object _bankSentinel = Object();

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

  const PaymentSplitState({
    this.totalAmount = 0,
    this.transactions = const [],
    this.currentInput = '',
    this.activeMethod = PaymentMethodType.cash,
    this.isProcessing = false,
    this.isPrinting = false,
    this.error,
    this.validationError,
    this.orderDetails,
    this.orderItems = const [],
    this.selectedBankAccount,
  });

  PaymentSplitState copyWith({
    double? totalAmount,
    List<PaymentTransaction>? transactions,
    String? currentInput,
    PaymentMethodType? activeMethod,
    bool? isProcessing,
    bool? isPrinting,
    String? error,
    String? validationError,
    Order? orderDetails,
    List<OrderItem>? orderItems,
    Object? selectedBankAccount = _bankSentinel,
  }) {
    return PaymentSplitState(
      totalAmount: totalAmount ?? this.totalAmount,
      transactions: transactions ?? this.transactions,
      currentInput: currentInput ?? this.currentInput,
      activeMethod: activeMethod ?? this.activeMethod,
      isProcessing: isProcessing ?? this.isProcessing,
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
    );
  }

  double get totalPaid => transactions.fold(0.0, (sum, t) => sum + t.amount);
  double get remaining =>
      (totalAmount - totalPaid) > 0 ? (totalAmount - totalPaid) : 0;
  double get change =>
      (totalPaid - totalAmount) > 0 ? (totalPaid - totalAmount) : 0;
  double get inputAmount => double.tryParse(currentInput) ?? 0;
  bool get isComplete => remaining <= 0.01; // Tolerance
}

// ==============================================================================
// 🧠 VIEW MODEL
// ==============================================================================

class PaymentSplitViewModel extends StateNotifier<PaymentSplitState> {
  final SalesRepositoryImproved _salesRepo;

  final String _orderId;
  final String? _checkId;
  final String? _customerId;
  final String? _fiscalType;
  final String? _cashierSessionId;
  final Ref _ref;

  /// Guard sincronico antes de cualquier `await` para bloquear
  /// double-tap / re-fire en el mismo frame. `state.isProcessing` es
  /// equivalente conceptualmente, pero el rebuild que lo expone al boton
  /// llega en el siguiente frame y deja una ventana de race minima.
  /// Este flag es field privado: las dos invocaciones lo ven sincrono.
  bool _localProcessing = false;

  PaymentSplitViewModel(
    this._salesRepo,
    this._orderId,
    double total, {
    String? checkId,
    String? customerId,
    String? fiscalType,
    String? cashierSessionId,
    required Ref ref,
  }) : _checkId = checkId,
       _customerId = customerId,
       _fiscalType = fiscalType,
       _cashierSessionId = cashierSessionId,
       _ref = ref,
       super(PaymentSplitState(totalAmount: total)) {
    _loadOrderForReceipt();
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

    if (raw.startsWith('Exception: ')) {
      return raw.substring('Exception: '.length);
    }

    return raw;
  }

  Future<String?> _resolveCashierSessionId() async {
    if (_cashierSessionId != null && _cashierSessionId.isNotEmpty) {
      return _cashierSessionId;
    }

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return null;

    final data = await Supabase.instance.client
        .from('cash_register_sessions')
        .select('id')
        .eq('user_id', userId)
        .eq('status', 'open')
        .isFilter('closed_at', null)
        .maybeSingle();

    return data?['id'] as String?;
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

  /// Marca/desmarca la fase de impresion. La pantalla la usa para
  /// mantener el modal abierto mientras corre el callback de print, y
  /// para deshabilitar los botones de cerrar mientras tanto.
  void setPrinting(bool value) {
    if (state.isPrinting == value) return;
    state = state.copyWith(isPrinting: value);
  }

  // --- INPUT HANDLING ---

  void setInput(String val) {
    state = state.copyWith(currentInput: val, validationError: null);
  }

  void appendInput(String char) {
    if (char == '.' && state.currentInput.contains('.')) return;
    state = state.copyWith(
      currentInput: state.currentInput + char,
      validationError: null,
    );
  }

  void backspace() {
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
    state = state.copyWith(currentInput: '', validationError: null);
  }

  void setMethod(PaymentMethodType method, {bool presetRemaining = true}) {
    state = state.copyWith(
      activeMethod: method,
      validationError: null,
      // Cambiar de método siempre limpia la cuenta bancaria seleccionada
      // (era válida solo para transferencia). Al volver a transfer, el
      // cajero tiene que volver a seleccionarla — UX explícita.
      selectedBankAccount: null,
    );
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
    state = state.copyWith(
      selectedBankAccount: account,
      validationError: null,
    );
  }

  void setQuickAmount(double amount) {
    state = state.copyWith(
      currentInput: amount.toStringAsFixed(0),
      validationError: null,
    );
  }

  void setExactAmount() {
    state = state.copyWith(
      currentInput: state.remaining.toStringAsFixed(2),
      validationError: null,
    );
  }

  // --- TRANSACTION MANAGEMENT (Split Logic) ---

  void addTransaction() {
    final amount = state.inputAmount;
    if (amount <= 0) {
      state = state.copyWith(validationError: 'Ingresa un monto mayor a cero.');
      return;
    }

    final allowsChange = state.activeMethod == PaymentMethodType.cash;
    final exceedsRemaining = amount - state.remaining > 0.01;
    if (exceedsRemaining && !allowsChange) {
      state = state.copyWith(
        validationError: 'El monto excede lo pendiente para este método.',
      );
      return;
    }

    // Si es transferencia, el cajero tiene que haber seleccionado a cuál
    // cuenta del negocio llegó. Sin esto, perdemos trazabilidad.
    if (state.activeMethod == PaymentMethodType.transfer &&
        state.selectedBankAccount == null) {
      state = state.copyWith(
        validationError: 'Selecciona la cuenta bancaria que recibió la transferencia.',
      );
      return;
    }

    final projectedRemaining = (state.remaining - amount).clamp(
      0.0,
      double.maxFinite,
    );

    final newTx = PaymentTransaction(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
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
  }

  void removeTransaction(String id) {
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
  }

  // --- CONFIRMATION & PRINTING ---

  Future<List<Payment>?> confirmPayment(BuildContext context) async {
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
    if (_localProcessing || state.isProcessing) return null;
    _localProcessing = true;

    state = state.copyWith(
      isProcessing: true,
      error: null,
      validationError: null,
    );

    final List<Payment> createdPayments = [];

    try {
      final cashierSessionId = await _resolveCashierSessionId();
      if (cashierSessionId == null || cashierSessionId.isEmpty) {
        state = state.copyWith(
          isProcessing: false,
          validationError: 'No hay una caja abierta para procesar el cobro.',
        );
        return null;
      }

      debugPrint(
        '💰 Confirming Payment: ${state.transactions.length} transactions',
      );

      // 1. Process all transactions
      for (int i = 0; i < state.transactions.length; i++) {
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
          default:
            methodId = 'cash';
        }

        debugPrint(
          'Processing Tx $i: method=$methodId, amount=${tx.amount}, checkId=$_checkId',
        );

        final payment = await _salesRepo
            .processPayment(
              orderId: _orderId,
              checkId: _checkId,
              paymentMethodId: methodId,
              amount: tx.amount,
              changeAmount: isLast ? state.change : 0,
              closeOrder: isLast && _checkId == null,
              customerId: _customerId,
              customerRnc: isLast
                  ? _ref.read(currentOrderProvider).customerTaxId
                  : null,
              fiscalType: _fiscalType,
              cashierSessionId: cashierSessionId,
              reference: null,
            )
            .catchError((e) {
              debugPrint('❌ Error in processPayment: $e');
              throw e;
            });

        debugPrint('✅ Payment Processed: ${payment.id}');

        // Si la transacción tiene cuenta bancaria asociada, asociarla
        // al payment recién creado vía UPDATE puntual. No tocamos el
        // RPC fiscal (zona sensible) — un round-trip extra es OK.
        // Si el UPDATE falla, log y continuar; el cobro ya está hecho.
        var enrichedPayment = payment.copyWith(
          paymentMethodCode: methodId,
          paymentMethodName: tx.methodLabel,
        );
        final bankAccount = tx.bankAccount;
        if (bankAccount != null) {
          try {
            await Supabase.instance.client
                .from('payments')
                .update({'bank_account_id': bankAccount.id})
                .eq('id', payment.id);
            enrichedPayment =
                enrichedPayment.copyWith(bankAccountId: bankAccount.id);
          } catch (e) {
            debugPrint(
              'No se pudo asociar bank_account a payment ${payment.id}: $e',
            );
          }
        }
        createdPayments.add(enrichedPayment);
      }

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
      try {
        final fiscalDocRow = await Supabase.instance.client
            .from('fiscal_documents')
            .select('id, is_electronic')
            .eq('order_id', _orderId)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();

        if (fiscalDocRow != null && fiscalDocRow['is_electronic'] == true) {
          final fiscalId = fiscalDocRow['id'] as String;
          final t0 = DateTime.now();
          debugPrint('[split-emit-sync] START doc=$fiscalId');
          try {
            final res = await Supabase.instance.client.functions
                .invoke(
                  'emit-document',
                  body: {'fiscal_document_id': fiscalId},
                )
                .timeout(const Duration(seconds: 8));
            final dt = DateTime.now().difference(t0).inMilliseconds;
            debugPrint(
              '[split-emit-sync] OK status=${res.status} dt=${dt}ms',
            );
          } on TimeoutException {
            final dt = DateTime.now().difference(t0).inMilliseconds;
            debugPrint('[split-emit-sync] TIMEOUT despues de ${dt}ms');
          } catch (e) {
            debugPrint('[split-emit-sync] ERROR exception=$e');
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
      state = state.copyWith(isProcessing: false, isPrinting: true);
      return createdPayments;
    } catch (e, stack) {
      debugPrint('❌ Fatal Error in confirmPayment: $e\n$stack');
      state = state.copyWith(
        isProcessing: false,
        error: _friendlyPaymentError(e),
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
      (String, double, String?, String?, String?)
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
        cashierSessionId: sessionId,
        ref: ref,
      );
    });
