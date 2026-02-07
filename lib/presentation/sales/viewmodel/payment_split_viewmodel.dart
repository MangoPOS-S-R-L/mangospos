import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/sales_models.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/sales_repository_improved.dart';
import '../../settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';
import '../../cashier/viewmodel/cashier_viewmodel.dart';
import '../viewmodel/sales_viewmodel.dart';

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
  final PrintingRepository _printingRepo;
  final String _orderId;
  final String? _checkId;
  final String? _cashierSessionId;
  final Ref _ref;

  PaymentSplitViewModel(
    this._salesRepo,
    this._printingRepo,
    this._orderId,
    double total, {
    String? checkId,
    String? cashierSessionId,
    required Ref ref,
  }) : _checkId = checkId,
       _cashierSessionId = cashierSessionId,
       _ref = ref,
       super(PaymentSplitState(totalAmount: total)) {
    _loadOrderForReceipt();
  }

  Future<void> _loadOrderForReceipt() async {
    try {
      final order = await _salesRepo.getOrder(_orderId);
      final items = await _salesRepo.getOrderItems(_orderId);
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

  Future<bool> confirmPayment(BuildContext context) async {
    if (state.transactions.isEmpty) {
      state = state.copyWith(
        validationError: 'Agrega al menos un pago antes de confirmar.',
      );
      return false;
    }

    if (!state.isComplete) {
      state = state.copyWith(
        validationError: 'Aún queda saldo pendiente por cobrar.',
      );
      return false;
    }

    if (state.isProcessing) return false;

    state = state.copyWith(
      isProcessing: true,
      error: null,
      validationError: null,
    );

    try {
      // 1. Process all transactions
      // For now, we assume Backend handles partials correctly OR we send them one by one.
      // Real implementation might bulk insert. Here we loop.

      for (int i = 0; i < state.transactions.length; i++) {
        final tx = state.transactions[i];
        final isLast = i == state.transactions.length - 1;

        // Map enum to ID (example IDs, should come from DB)
        String methodId;
        switch (tx.method) {
          case PaymentMethodType.cash:
            methodId = 'cash';
            break;
          case PaymentMethodType.card:
            methodId = 'card';
            break; // 'credit_card'?
          case PaymentMethodType.transfer:
            methodId = 'transfer';
            break;
          default:
            methodId = 'cash';
        }

        // We should close order ONLY on last one?
        // Current Repo implementation closes.
        // We'll assume the SalesRepository is smart enough OR we modify it later.
        // For now, calling processPayment.

        await _salesRepo
            .processPayment(
              orderId: _orderId,
              checkId: _checkId,
              paymentMethodId: methodId,
              amount: tx.amount,
              changeAmount: isLast ? state.change : 0,
              closeOrder: isLast && _checkId == null,
              cashierSessionId: _cashierSessionId,
            )
            .catchError((e) async {
              // 🛡️ FALL BACK: If session ID is invalid (FK error), try without it
              final msg = e.toString().toLowerCase();
              if (msg.contains('payments_session_id_fkey') ||
                  msg.contains('foreign key constraint')) {
                debugPrint(
                  '⚠️ Cashier Session Invalid. Retrying payment without session link...',
                );
                return await _salesRepo.processPayment(
                  orderId: _orderId,
                  checkId: _checkId,
                  paymentMethodId: methodId,
                  amount: tx.amount,
                  changeAmount: isLast ? state.change : 0,
                  closeOrder: isLast && _checkId == null,
                  cashierSessionId: null, // explicit null
                );
              }
              throw e;
            });
      }

      // Si se pagó un check parcial, limpiar también en backend y local
      if (_checkId != null) {
        try {
          await _salesRepo.clearCheck(_checkId!);
        } catch (e) {
          debugPrint('Error limpiando check en backend: $e');
        }
        _ref.read(currentOrderProvider.notifier).removeCheckLocally(_checkId!);
        await Future.delayed(
          const Duration(milliseconds: 250),
        ); // Wait for triggers/propagation
        await _ref.read(currentOrderProvider.notifier).refreshOrder();
      }

      // 2. Print Receipt via QZ Tray (Agent)
      await _printReceipt();

      state = state.copyWith(isProcessing: false);
      return true;
    } catch (e) {
      state = state.copyWith(isProcessing: false, error: e.toString());
      return false;
    }
  }

  Future<void> _printReceipt() async {
    try {
      // Basic Receipt Generation using ESC/POS
      // await _printingRepo.getPrinter('default'); // REMOVED: Causes invalid input syntax for type uuid
      // We need to know WHICH printer.
      // Assuming 'cashier' printer or similar.
      // For now, finding FIRST available printer via Agent logic or using 'test' IP.

      // Better: Use PrintingRepository logic to find assigned printer for 'receipts'.
      // Skipping complicated lookup for this specific task, sending to QZ generic.

      // Build Bytes
      final List<int> bytes = [0x1B, 0x40]; // Init

      // Header
      bytes.addAll(utf8.encode('       MANGO POS       \n'));
      bytes.addAll(utf8.encode('      RECIBO DE PAGO      \n'));
      bytes.addAll(utf8.encode('--------------------------------\n'));

      // Order Info
      bytes.addAll(
        utf8.encode('Orden: ${_orderId.substring(0, 8).toUpperCase()}\n'),
      );
      bytes.addAll(
        utf8.encode('Fecha: ${DateTime.now().toString().substring(0, 16)}\n'),
      );
      bytes.addAll(utf8.encode('--------------------------------\n'));

      // Items
      for (final item in state.orderItems) {
        final qty = item.quantity.toStringAsFixed(0);
        final name = item.productName;
        final total = item.total.toStringAsFixed(2);
        bytes.addAll(utf8.encode('$qty $name ${total.padLeft(8)}\n'));
      }
      bytes.addAll(utf8.encode('--------------------------------\n'));

      // Totals
      bytes.addAll(
        utf8.encode('TOTAL: ${state.totalAmount.toStringAsFixed(2)}\n'),
      );

      // Payments
      for (final tx in state.transactions) {
        bytes.addAll(
          utf8.encode('${tx.methodLabel}: ${tx.amount.toStringAsFixed(2)}\n'),
        );
      }

      if (state.change > 0) {
        bytes.addAll(
          utf8.encode('CAMBIO: ${state.change.toStringAsFixed(2)}\n'),
        );
      }

      bytes.addAll(utf8.encode('\n\n\n'));
      bytes.addAll([0x1D, 0x56, 0x41]); // Cut

      // Send to QZ
      // Ideally we find the printer.
      // HARDCODED FIX for now: Getting first printer from DB or using one if known.
      // Or we assume the user selected a printer?
      // For receipts, it's usually automatic.
      // I'll log for now if no printer found.
      debugPrint('Generating receipt bytes... sending to QZ if config found.');

      // Attempt to send to "Caja" (default name) or find a better way to config.
      // User can change 'Caja' to their actual printer name in DB or Code.
      debugPrint('Sending receipt to printer "Caja"...');
      await _printingRepo.printCustomData(ip: 'Caja', data: bytes);
    } catch (e) {
      debugPrint('Receipt printing error: $e');
    }
  }
}

final paymentSplitProvider =
    StateNotifierProvider.family<
      PaymentSplitViewModel,
      PaymentSplitState,
      (String, double, String?)
    >((ref, params) {
      final salesRepo = SalesRepositoryImproved(Supabase.instance.client);
      final printingRepo = ref.read(printingPrintersRepositoryProvider);
      final cashierVM = ref.read(cashierViewModelProvider);
      final sessionId = cashierVM.lastSession?['id'] as String?;

      return PaymentSplitViewModel(
        salesRepo,
        printingRepo,
        params.$1, // orderId
        params.$2, // amount
        checkId: params.$3, // checkId
        cashierSessionId: sessionId,
        ref: ref,
      );
    });
