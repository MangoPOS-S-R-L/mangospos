import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/credits_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import '../state/credit_payment_receipt.dart';

final creditsRepositoryProvider = Provider<CreditsRepository>((ref) {
  return CreditsRepository(Supabase.instance.client);
});

final creditsViewModelProvider = ChangeNotifierProvider<CreditsViewModel>((
  ref,
) {
  return CreditsViewModel(ref.read(creditsRepositoryProvider));
});

class CreditsViewModel extends ChangeNotifier {
  final CreditsRepository _repository;

  bool _isLoading = false;
  String? _businessId;
  String? _error;
  List<Map<String, dynamic>> _receivables = [];
  List<Map<String, dynamic>> _payables = [];

  CreditsViewModel(this._repository);

  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get businessId => _businessId;
  List<Map<String, dynamic>> get receivables => _receivables;
  List<Map<String, dynamic>> get payables => _payables;

  Future<void> init() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final client = Supabase.instance.client;
      _businessId = await resolveBusinessIdOrNull(client, 'auto');
      if (_businessId != null) {
        await _fetchAll();
      }
    } catch (e) {
      _error = e.toString();
      debugPrint('Error loading credits: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> reload() async {
    if (_businessId == null) return init();
    _isLoading = true;
    notifyListeners();
    try {
      await _fetchAll();
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _fetchAll() async {
    final bid = _businessId;
    if (bid == null) return;
    final results = await Future.wait([
      _repository.getReceivables(bid),
      _repository.getPayables(bid),
    ]);
    _receivables = results[0];
    _payables = results[1];
  }

  /// Vencida = con saldo y due_date pasada (status overdue solo derivado).
  static bool isOverdue(Map<String, dynamic> credit) {
    final status = credit['status'] as String?;
    if (status == 'paid' || status == 'cancelled') return false;
    final due = credit['due_date'] as String?;
    if (due == null || due.isEmpty) return false;
    final dueDate = DateTime.tryParse(due);
    if (dueDate == null) return false;
    final now = DateTime.now();
    return dueDate.isBefore(DateTime(now.year, now.month, now.day));
  }

  double get totalReceivableOpen => _openTotal(_receivables);
  double get totalPayableOpen => _openTotal(_payables);
  double get totalReceivableOverdue => _overdueTotal(_receivables);
  double get totalPayableOverdue => _overdueTotal(_payables);

  static double _openTotal(List<Map<String, dynamic>> credits) {
    double total = 0;
    for (final c in credits) {
      final status = c['status'] as String?;
      if (status == 'paid' || status == 'cancelled') continue;
      total += ((c['balance'] as num?) ?? 0).toDouble();
    }
    return total;
  }

  static double _overdueTotal(List<Map<String, dynamic>> credits) {
    double total = 0;
    for (final c in credits) {
      if (!isOverdue(c)) continue;
      total += ((c['balance'] as num?) ?? 0).toDouble();
    }
    return total;
  }

  /// Abono a una CxC. Si es en efectivo necesita la caja abierta del usuario
  /// (el RPC registra el depósito en esa sesión).
  /// Registra un abono y devuelve el recibo para imprimirlo.
  ///
  /// Devuelve `null` cuando la BD todavía no tiene `fn_register_credit_abono_v2`
  /// (mig 20260902_0002 sin aplicar): el abono SÍ quedó registrado, lo único
  /// que no hay es número de recibo. Quien llama tiene que distinguir esos
  /// dos casos y no decirle al cajero que el abono falló.
  Future<CreditPaymentReceipt?> registerReceivableAbono({
    required String creditId,
    required double amount,
    required String paymentMethodCode,
    String? reference,
  }) async {
    final sessionId = await _resolveCashSessionId(
      requiredForCash: paymentMethodCode == 'cash',
    );
    final result = await _repository.registerReceivableAbono(
      creditId: creditId,
      amount: amount,
      paymentMethodCode: paymentMethodCode,
      reference: reference,
      sessionId: sessionId,
    );
    await reload();

    final payment = result['payment'];
    if (payment is! Map) return null;
    return CreditPaymentReceipt.fromRpc(Map<String, dynamic>.from(payment));
  }

  /// Pago/abono a una CxP. El efectivo sale de caja solo si hay caja abierta.
  Future<void> registerPayablePayment({
    required String creditId,
    required double amount,
    required String paymentMethodCode,
    String? reference,
    bool affectCashSession = true,
  }) async {
    String? sessionId;
    if (paymentMethodCode == 'cash' && affectCashSession) {
      sessionId = await _resolveCashSessionId(requiredForCash: false);
    }
    await _repository.registerPayablePayment(
      creditId: creditId,
      amount: amount,
      paymentMethodCode: paymentMethodCode,
      reference: reference,
      sessionId: sessionId,
    );
    await reload();
  }

  Future<void> createManualPayable({
    required String supplierId,
    required double amount,
    String? invoiceNumber,
    DateTime? dueDate,
    String? notes,
  }) async {
    final bid = _businessId;
    if (bid == null) throw Exception('Negocio no resuelto');
    await _repository.createPayable(
      businessId: bid,
      supplierId: supplierId,
      amount: amount,
      invoiceNumber: invoiceNumber,
      dueDate: dueDate,
      notes: notes,
    );
    await reload();
  }

  Future<void> cancelReceivable(String creditId, {String? reason}) async {
    await _repository.cancelReceivable(creditId, reason: reason);
    await reload();
  }

  Future<void> cancelPayable(String creditId, {String? reason}) async {
    await _repository.cancelPayable(creditId, reason: reason);
    await reload();
  }

  Future<List<Map<String, dynamic>>> getReceivablePayments(String creditId) {
    return _repository.getReceivablePayments(creditId);
  }

  Future<List<Map<String, dynamic>>> getPayablePayments(String creditId) {
    return _repository.getPayablePayments(creditId);
  }

  Future<List<Map<String, dynamic>>> getSuppliers() async {
    final bid = _businessId;
    if (bid == null) return const [];
    final rows = await Supabase.instance.client
        .from('suppliers')
        .select('id, name')
        .eq('business_id', bid)
        .eq('is_active', true)
        .order('name');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<String?> _resolveCashSessionId({required bool requiredForCash}) async {
    final bid = _businessId;
    if (bid == null) return null;
    final cashierRepo = CashierRepository(Supabase.instance.client);
    final session = await cashierRepo.getCurrentUserActiveSessionForBusiness(
      businessId: bid,
    );
    if (session == null && requiredForCash) {
      throw Exception(
        'Necesitas una caja abierta para recibir abonos en efectivo.',
      );
    }
    return session?.id;
  }
}
