import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/payment_models.dart';
import '../../../data/models/sales_models.dart';
import '../../../data/repositories/cashier_repository_new.dart';
import '../../../data/repositories/sales_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../../sales/viewmodel/sales_viewmodel.dart'; // Import para usar salesRepositoryProvider
import '../state/payment_state.dart';

// Providers
final cashierRepositoryProvider = Provider<CashierRepository>(
  (ref) => CashierRepository(Supabase.instance.client),
);

final paymentViewModelProvider =
    StateNotifierProvider.autoDispose<PaymentViewModel, PaymentState>(
      (ref) => PaymentViewModel(
        ref.read(cashierRepositoryProvider),
        ref.read(salesRepositoryProvider),
      ),
    );

/// 💰 ViewModel para gestión de pagos
class PaymentViewModel extends StateNotifier<PaymentState> {
  final CashierRepository _cashierRepo;
  final SalesRepository _salesRepo;

  PaymentViewModel(this._cashierRepo, this._salesRepo)
    : super(const PaymentState());

  String _cleanError(Object e) {
    if (e is TimeoutException || e is SocketException) {
      return 'Error de conexion con el servidor.';
    }
    if (e is PostgrestException) {
      final message = e.message.trim();
      final details = (e.details ?? '').toString().trim();
      final hint = (e.hint ?? '').toString().trim();
      final combined = [
        if (message.isNotEmpty) message,
        if (details.isNotEmpty) details,
        if (hint.isNotEmpty) hint,
      ].join(' - ');
      return combined.isEmpty ? 'Error de conexion con el servidor.' : combined;
    }
    final msg = e.toString();
    const prefixes = ['Exception: '];
    for (final prefix in prefixes) {
      if (msg.startsWith(prefix)) {
        return msg.substring(prefix.length);
      }
    }
    return msg;
  }

  // ============================================================
  // 🚀 INICIALIZACIÓN
  // ============================================================

  /// Inicializar pago para una orden completa
  Future<void> initializeForOrder(Order order) async {
    state = state.copyWith(
      loading: true,
      error: null,
      order: order,
      totalToPay: order.total,
    );

    try {
      // Validar sesión de caja
      final cashSession = await _cashierRepo.requireActiveSession();

      // Obtener métodos de pago
      final businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );

      if (businessId == null) {
        throw Exception('No se pudo identificar el negocio');
      }

      var methods = await _cashierRepo.getPaymentMethods(businessId);

      // Combinar con métodos fijos si no están presentes
      final fixedMethods = _getFixedPaymentMethods(businessId);
      for (final fixed in fixedMethods) {
        if (!methods.any((m) => m.code == fixed.code)) {
          methods = [...methods, fixed];
        }
      }

      // Ordenar por posición
      methods.sort((a, b) => a.position.compareTo(b.position));

      state = state.copyWith(
        loading: false,
        order: order,
        totalToPay: order.total,
        paymentMethods: methods,
        cashSession: cashSession,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: _cleanError(e));
    }
  }

  /// Inicializar pago para un check específico (split bill)
  Future<void> initializeForCheck(Order order, OrderCheck check) async {
    state = state.copyWith(
      loading: true,
      error: null,
      order: order,
      check: check,
      totalToPay: check.total,
    );

    try {
      // Validar sesión de caja
      final cashSession = await _cashierRepo.requireActiveSession();

      // Obtener métodos de pago
      final businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );

      if (businessId == null) {
        throw Exception('No se pudo identificar el negocio');
      }

      var methods = await _cashierRepo.getPaymentMethods(businessId);

      // Combinar con métodos fijos si no están presentes
      final fixedMethods = _getFixedPaymentMethods(businessId);
      for (final fixed in fixedMethods) {
        if (!methods.any((m) => m.code == fixed.code)) {
          methods = [...methods, fixed];
        }
      }

      // Ordenar por posición
      methods.sort((a, b) => a.position.compareTo(b.position));

      state = state.copyWith(
        loading: false,
        order: order,
        check: check,
        totalToPay: check.total,
        paymentMethods: methods,
        cashSession: cashSession,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: _cleanError(e));
    }
  }

  // ============================================================
  // 💳 SELECCIÓN DE MÉTODO DE PAGO
  // ============================================================

  void selectPaymentMethod(PaymentMethod method) {
    state = state.copyWith(
      selectedMethod: method,
      amountReceived: method.isCash ? 0 : state.totalToPay,
      change: 0,
      reference: null,
    );
  }

  // ============================================================
  // 💵 PAGO EN EFECTIVO
  // ============================================================

  void setAmountReceived(double amount) {
    final change = amount - state.totalToPay;
    state = state.copyWith(
      amountReceived: amount,
      change: change > 0 ? change : 0,
    );
  }

  void addToAmountReceived(double amount) {
    setAmountReceived(state.amountReceived + amount);
  }

  void setExactAmount() {
    setAmountReceived(state.totalToPay);
  }

  void clearAmountReceived() {
    state = state.copyWith(amountReceived: 0, change: 0);
  }

  // ============================================================
  // 📝 REFERENCIA Y CLIENTE
  // ============================================================

  void setReference(String? reference) {
    state = state.copyWith(reference: reference);
  }

  void setCustomer({
    String? customerId,
    String? customerRnc,
    String? customerName,
  }) {
    state = state.copyWith(
      customerId: customerId,
      customerRnc: customerRnc,
      customerName: customerName,
    );
  }

  // ============================================================
  // ✅ PROCESAR PAGO
  // ============================================================

  Future<void> processPayment() async {
    if (!state.canProcessPayment) {
      state = state.copyWith(
        error: 'No se puede procesar el pago. Verifica los datos.',
      );
      return;
    }

    state = state.copyWith(loading: true, error: null);

    try {
      final orderId = state.order!.id;
      final checkId = state.check?.id;
      final methodId = state.selectedMethod!.id;
      final amount = state.amountReceived > 0
          ? state.amountReceived
          : state.totalToPay;
      final reference = state.reference;
      final customerId = state.customerId;
      final customerRnc = state.customerRnc;

      // Procesar pago en el backend
      final payment = await _salesRepo.processPayment(
        orderId: orderId,
        checkId: checkId,
        paymentMethodId: methodId,
        amount: amount,
        reference: reference,
        customerId: customerId,
        customerRnc: customerRnc,
        cashierSessionId: state.cashSession?.id,
        changeAmount: state.change,
      );

      // Obtener documento fiscal generado
      FiscalDocument? fiscalDoc;
      try {
        fiscalDoc = await _salesRepo.getOrderFiscalDocument(orderId);
      } catch (e) {
        // Si no se generó documento fiscal, continuar
      }

      state = state.copyWith(
        loading: false,
        paymentProcessed: true,
        processedPayment: payment,
        fiscalDocument: fiscalDoc,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error al procesar pago: ${_cleanError(e)}',
      );
    }
  }

  // ============================================================
  // 🔄 RESET
  // ============================================================

  void reset() {
    state = const PaymentState();
  }

  // ============================================================
  // 🔒 MÉTODOS FIJOS
  // ============================================================

  List<PaymentMethod> _getFixedPaymentMethods(String businessId) {
    return [
      PaymentMethod(
        id: 'cash',
        businessId: businessId,
        name: 'Efectivo',
        code: 'cash',
        isActive: true,
        requiresReference: false,
        icon: 'cash',
        position: 1,
      ),
      PaymentMethod(
        id: 'card',
        businessId: businessId,
        name: 'Tarjeta',
        code: 'card',
        isActive: true,
        requiresReference: true,
        icon: 'card',
        position: 2,
      ),
      PaymentMethod(
        id: 'transfer',
        businessId: businessId,
        name: 'Transferencia',
        code: 'transfer',
        isActive: true,
        requiresReference: true,
        icon: 'transfer',
        position: 3,
      ),
    ];
  }
}
