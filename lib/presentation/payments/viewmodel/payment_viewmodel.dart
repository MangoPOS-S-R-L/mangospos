import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/connectivity_service.dart';
import '../../../core/offline/offline_pos_service.dart';
import '../../../data/models/payment_models.dart';
import '../../../data/models/sales_models.dart';
import '../../../data/repositories/cashier_repository.dart';
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
  final ConnectivityService _connectivity = ConnectivityService();
  final OfflinePosService _offlinePos = OfflinePosService();

  PaymentViewModel(this._cashierRepo, this._salesRepo)
    : super(const PaymentState()) {
    unawaited(_connectivity.initialize());
  }

  @override
  void dispose() {
    _connectivity.dispose();
    super.dispose();
  }

  String _cleanError(Object e) {
    final raw = e.toString();
    if (raw.contains('Demasiadas colisiones de NCF')) {
      return 'No se pudo emitir el comprobante fiscal de este negocio porque su numeracion entra en conflicto con otra configuracion fiscal. Revisa Ajustes > Fiscal.';
    }
    if (raw.contains('No hay secuencia NCF disponible para tipo') ||
        raw.contains('Secuencia NCF agotada para tipo')) {
      return 'El negocio no tiene una secuencia fiscal activa para el tipo de comprobante seleccionado. Revisa Ajustes > Fiscal.';
    }
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
    await _initializePayment(order: order, totalToPay: order.total);
  }

  /// Inicializar pago para un check específico (split bill)
  Future<void> initializeForCheck(Order order, OrderCheck check) async {
    await _initializePayment(
      order: order,
      check: check,
      totalToPay: check.total,
    );
  }

  Future<void> _initializePayment({
    required Order order,
    OrderCheck? check,
    required double totalToPay,
  }) async {
    state = state.copyWith(
      loading: true,
      error: null,
      order: order,
      check: check,
      totalToPay: totalToPay,
      offlineQueued: false,
    );

    try {
      CashRegisterSession? cashSession;
      if (_connectivity.isConnected) {
        cashSession = await _cashierRepo.requireActiveSession();
      }

      final businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );

      if (businessId == null) {
        throw Exception('No se pudo identificar el negocio');
      }

      var methods = <PaymentMethod>[];
      if (_connectivity.isConnected) {
        methods = await _cashierRepo.getPaymentMethods(businessId);
      }

      final fixedMethods = _getFixedPaymentMethods(businessId);
      for (final fixed in fixedMethods) {
        if (!methods.any((m) => m.code == fixed.code)) {
          methods = [...methods, fixed];
        }
      }

      methods.sort((a, b) => a.position.compareTo(b.position));

      state = state.copyWith(
        loading: false,
        order: order,
        check: check,
        totalToPay: totalToPay,
        paymentMethods: methods,
        cashSession: cashSession,
        error: _connectivity.isConnected
            ? null
            : 'Modo offline: el pago se guardará para sincronizar luego.',
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

    state = state.copyWith(processingPayment: true, error: null);

    final orderId = state.order!.id;
    final checkId = state.check?.id;
    final methodId = state.selectedMethod!.id;
    final amount = state.amountReceived > 0
        ? state.amountReceived
        : state.totalToPay;
    final reference = state.reference;
    final customerId = state.customerId;
    final customerRnc = state.customerRnc;

    try {
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

      FiscalDocument? fiscalDoc;
      try {
        fiscalDoc = await _salesRepo.getOrderFiscalDocument(orderId);
      } catch (_) {}

      state = state.copyWith(
        processingPayment: false,
        paymentProcessed: true,
        processedPayment: payment,
        fiscalDocument: fiscalDoc,
        offlineQueued: false,
      );
    } catch (e) {
      final shouldQueueOffline =
          !_connectivity.isConnected ||
          orderId.startsWith('local-order-') ||
          e is TimeoutException ||
          e is SocketException;
      if (!shouldQueueOffline) {
        state = state.copyWith(
          processingPayment: false,
          error: 'Error al procesar pago: ${_cleanError(e)}',
        );
        return;
      }

      try {
        final businessId = await resolveBusinessIdOrNull(
          Supabase.instance.client,
          'auto',
        );
        if (businessId == null || businessId.isEmpty) {
          throw Exception('No se pudo identificar el negocio');
        }

        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'process_payment',
            'origin': state.order?.id.startsWith('local-order-') == true
                ? 'offline'
                : 'remote',
            'order_id': orderId,
            'check_id': checkId,
            'payment_method_id': methodId,
            'payment_method_code': state.selectedMethod?.code,
            'payment_method_name': state.selectedMethod?.name,
            'amount': amount,
            'reference': reference,
            'customer_id': customerId,
            'customer_rnc': customerRnc,
            'cashier_session_id': state.cashSession?.id,
            'change_amount': state.change,
          },
        );

        final businessPaymentId =
            'local-payment-${DateTime.now().millisecondsSinceEpoch}';
        final localPayment = Payment(
          id: businessPaymentId,
          businessId: businessId,
          orderId: orderId,
          checkId: checkId,
          paymentMethodId: methodId,
          paymentMethodCode: state.selectedMethod?.code,
          paymentMethodName: state.selectedMethod?.name,
          amount: amount,
          reference: reference,
          changeAmount: state.change,
          status: 'pending',
          sessionId: state.cashSession?.id,
          createdAt: DateTime.now(),
        );

        state = state.copyWith(
          processingPayment: false,
          paymentProcessed: true,
          processedPayment: localPayment,
          fiscalDocument: null,
          offlineQueued: true,
          error: 'Pago guardado en local. Pendiente de sincronizar.',
        );
      } catch (offlineError) {
        state = state.copyWith(
          processingPayment: false,
          error: 'Error al guardar pago offline: ${_cleanError(offlineError)}',
        );
      }
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
