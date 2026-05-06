import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/sales_models.dart';

import '../../../data/repositories/sales_repository_improved.dart';
import '../../cashier/viewmodel/cashier_viewmodel.dart';
import '../viewmodel/sales_viewmodel.dart';
import '../../../services/session/session_controller.dart';

// ==============================================================================
// 📦 MODELS
// ==============================================================================

enum PaymentMethodType { cash, card, transfer, other }

class PaymentTransaction {
  final String id;
  final PaymentMethodType method;
  final double amount;
  final DateTime timestamp;
  final String? reference; // For card ref, auth code, etc.

  PaymentTransaction({
    required this.id,
    required this.method,
    required this.amount,
    required this.timestamp,
    this.reference,
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
  final String? error;
  final String? validationError;
  final Order? orderDetails; // For printing
  final List<OrderItem> orderItems; // For printing

  const PaymentSplitState({
    this.totalAmount = 0,
    this.transactions = const [],
    this.currentInput = '',
    this.activeMethod = PaymentMethodType.cash,
    this.isProcessing = false,
    this.error,
    this.validationError,
    this.orderDetails,
    this.orderItems = const [],
  });

  PaymentSplitState copyWith({
    double? totalAmount,
    List<PaymentTransaction>? transactions,
    String? currentInput,
    PaymentMethodType? activeMethod,
    bool? isProcessing,
    String? error,
    String? validationError,
    Order? orderDetails,
    List<OrderItem>? orderItems,
  }) {
    return PaymentSplitState(
      totalAmount: totalAmount ?? this.totalAmount,
      transactions: transactions ?? this.transactions,
      currentInput: currentInput ?? this.currentInput,
      activeMethod: activeMethod ?? this.activeMethod,
      isProcessing: isProcessing ?? this.isProcessing,
      error: error,
      validationError: validationError,
      orderDetails: orderDetails ?? this.orderDetails,
      orderItems: orderItems ?? this.orderItems,
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
    state = state.copyWith(activeMethod: method, validationError: null);
    // Prefill with remaining for convenience when no input is present.
    if (presetRemaining && (state.inputAmount == 0) && state.remaining > 0) {
      state = state.copyWith(currentInput: state.remaining.toStringAsFixed(2));
    }
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

    final projectedRemaining = (state.remaining - amount).clamp(
      0.0,
      double.maxFinite,
    );

    final newTx = PaymentTransaction(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      method: state.activeMethod,
      amount: amount,
      timestamp: DateTime.now(),
    );

    state = state.copyWith(
      transactions: [...state.transactions, newTx],
      currentInput: projectedRemaining > 0
          ? projectedRemaining.toStringAsFixed(2)
          : '',
      validationError: null,
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

    if (state.isProcessing) return null;

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
        createdPayments.add(
          payment.copyWith(
            paymentMethodCode: methodId,
            paymentMethodName: tx.methodLabel,
          ),
        );
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

      state = state.copyWith(isProcessing: false);
      return createdPayments;
    } catch (e, stack) {
      debugPrint('❌ Fatal Error in confirmPayment: $e\n$stack');
      state = state.copyWith(
        isProcessing: false,
        error: _friendlyPaymentError(e),
      );
      return null;
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
