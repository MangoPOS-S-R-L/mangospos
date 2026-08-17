import 'package:supabase_flutter/supabase_flutter.dart';

import '../datasources/queries/credits_queries.dart';

/// Acceso a cuentas por cobrar (customer_credits) y por pagar
/// (supplier_credits). Los abonos van por RPC security definer para que el
/// efectivo entre/salga de la caja abierta de forma atómica.
class CreditsRepository {
  final SupabaseClient _client;

  CreditsRepository(this._client);

  // ── Cuentas por cobrar (CxC) ──────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getReceivables(
    String businessId, {
    bool onlyOpen = false,
  }) async {
    var query = _client
        .from(CreditsQueries.tableCustomerCredits)
        .select(CreditsQueries.selectReceivables)
        .eq('business_id', businessId);
    if (onlyOpen) {
      query = query.inFilter('status', ['pending', 'partial', 'overdue']);
    }
    final response = await query.order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(response);
  }

  Future<List<Map<String, dynamic>>> getReceivablePayments(
    String creditId,
  ) async {
    final response = await _client
        .from(CreditsQueries.tableCreditPayments)
        .select(CreditsQueries.selectReceivablePayments)
        .eq('credit_id', creditId)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(response);
  }

  Future<Map<String, dynamic>> registerReceivableAbono({
    required String creditId,
    required double amount,
    String paymentMethodCode = 'cash',
    String? reference,
    String? sessionId,
  }) async {
    final response = await _client.rpc(
      CreditsQueries.rpcRegisterCreditAbono,
      params: {
        'p_credit_id': creditId,
        'p_amount': amount,
        'p_payment_method_code': paymentMethodCode,
        'p_reference': reference,
        'p_session_id': sessionId,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  /// Cancela (condona) una cuenta por cobrar. NO revierte la venta ni el
  /// NCF — es un write-off: la deuda se perdona y libera el cupo del
  /// cliente. Graba quién/cuándo (mig 20260725_0003); si la BD aún no tiene
  /// esas columnas (42703), cae al update legacy de status+notes.
  Future<void> cancelReceivable(String creditId, {String? reason}) async {
    final base = <String, dynamic>{
      'status': 'cancelled',
      if (reason != null && reason.trim().isNotEmpty) 'notes': reason.trim(),
    };
    try {
      await _client
          .from(CreditsQueries.tableCustomerCredits)
          .update({
            ...base,
            'cancelled_by': _client.auth.currentUser?.id,
            'cancelled_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', creditId);
    } on PostgrestException catch (e) {
      if (e.code == '42703') {
        await _client
            .from(CreditsQueries.tableCustomerCredits)
            .update(base)
            .eq('id', creditId);
      } else {
        rethrow;
      }
    }
  }

  /// Situación crediticia del cliente para validar ANTES de cobrar a crédito:
  /// crédito habilitado, límite y deuda viva.
  Future<CustomerCreditStanding> getCustomerCreditStanding({
    required String businessId,
    required String customerId,
  }) async {
    final customer = await _client
        .from('customers')
        .select('credit_enabled, credit_limit, credit_days')
        .eq('id', customerId)
        .eq('business_id', businessId)
        .maybeSingle();

    final credits = await _client
        .from(CreditsQueries.tableCustomerCredits)
        .select('balance')
        .eq('business_id', businessId)
        .eq('customer_id', customerId)
        .inFilter('status', ['pending', 'partial', 'overdue']);

    double openBalance = 0;
    for (final row in credits) {
      openBalance += ((row['balance'] as num?) ?? 0).toDouble();
    }

    return CustomerCreditStanding(
      creditEnabled: (customer?['credit_enabled'] as bool?) ?? false,
      creditLimit: (customer?['credit_limit'] as num?)?.toDouble(),
      creditDays: (customer?['credit_days'] as num?)?.toInt(),
      openBalance: openBalance,
      customerFound: customer != null,
    );
  }

  /// Garantiza que el negocio tenga el método de pago `credit` (negocios
  /// creados antes de la migración o nuevos). Best-effort: no propaga error.
  Future<void> ensureCreditPaymentMethod(String businessId) async {
    try {
      await _client.rpc(
        CreditsQueries.rpcEnsureCreditPaymentMethod,
        params: {'p_business_id': businessId},
      );
    } catch (_) {
      // Sin conectividad o RPC aún no desplegado: el cobro a crédito fallará
      // con INVALID_PAYMENT_METHOD y la UI lo informa.
    }
  }

  // ── Cuentas por pagar (CxP) ───────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getPayables(
    String businessId, {
    bool onlyOpen = false,
  }) async {
    Future<List<Map<String, dynamic>>> fetch(String columns) async {
      var query = _client
          .from(CreditsQueries.tableSupplierCredits)
          .select(columns)
          .eq('business_id', businessId);
      if (onlyOpen) {
        query = query.inFilter('status', ['pending', 'partial', 'overdue']);
      }
      final response = await query.order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(response);
    }

    try {
      return await fetch(CreditsQueries.selectPayables);
    } on PostgrestException catch (e) {
      // Sin la migración 20260814_0003 no existe `ncf`: la pantalla de
      // Créditos no puede quedarse en blanco por una columna opcional.
      if (e.code != '42703' && e.code != 'PGRST200') rethrow;
      return fetch(CreditsQueries.selectPayablesLegacy);
    }
  }

  Future<List<Map<String, dynamic>>> getPayablePayments(
    String creditId,
  ) async {
    final response = await _client
        .from(CreditsQueries.tableSupplierCreditPayments)
        .select(CreditsQueries.selectPayablePayments)
        .eq('supplier_credit_id', creditId)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Crea la cuenta por pagar. [ncf] es el comprobante fiscal de la factura
  /// que la originó: se copia aquí para que la deuda sea consultable sin
  /// volver a la compra (mig 20260814_0003).
  Future<Map<String, dynamic>> createPayable({
    required String businessId,
    required String supplierId,
    required double amount,
    String? purchaseOrderId,
    String? invoiceNumber,
    String? ncf,
    DateTime? dueDate,
    String? notes,
  }) async {
    final payload = <String, dynamic>{
      'business_id': businessId,
      'supplier_id': supplierId,
      'purchase_order_id': purchaseOrderId,
      'invoice_number': invoiceNumber,
      'original_amount': amount,
      'balance': amount,
      'due_date': dueDate?.toIso8601String().substring(0, 10),
      'notes': notes,
      'created_by': _client.auth.currentUser?.id,
    };
    final hasNcf = ncf != null && ncf.trim().isNotEmpty;

    try {
      final response = await _client
          .from(CreditsQueries.tableSupplierCredits)
          .insert({
            ...payload,
            if (hasNcf) 'ncf': ncf.trim(),
          })
          .select(CreditsQueries.selectPayables)
          .single();
      return Map<String, dynamic>.from(response);
    } on PostgrestException catch (e) {
      // Sin la migración aplicada, perder la copia del NCF es mucho menos
      // grave que perder la deuda: se reintenta sin él. El NCF sigue vivo en
      // la orden de compra, que es su origen.
      if (e.code != '42703') rethrow;
      final response = await _client
          .from(CreditsQueries.tableSupplierCredits)
          .insert(payload)
          .select(CreditsQueries.selectPayablesLegacy)
          .single();
      return Map<String, dynamic>.from(response);
    }
  }

  Future<Map<String, dynamic>> registerPayablePayment({
    required String creditId,
    required double amount,
    String paymentMethodCode = 'cash',
    String? reference,
    String? sessionId,
  }) async {
    final response = await _client.rpc(
      CreditsQueries.rpcRegisterSupplierCreditPayment,
      params: {
        'p_credit_id': creditId,
        'p_amount': amount,
        'p_payment_method_code': paymentMethodCode,
        'p_reference': reference,
        'p_session_id': sessionId,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<void> cancelPayable(String creditId, {String? reason}) async {
    await _client
        .from(CreditsQueries.tableSupplierCredits)
        .update({
          'status': 'cancelled',
          if (reason != null && reason.trim().isNotEmpty)
            'notes': reason.trim(),
        })
        .eq('id', creditId);
  }
}

class CustomerCreditStanding {
  final bool creditEnabled;
  final double? creditLimit;
  final int? creditDays;
  final double openBalance;

  /// false = la consulta de `customers` no devolvió fila para ese id +
  /// business (cliente de otra sucursal, o RLS). Distinto de "crédito
  /// deshabilitado" — la UI debe explicar el caso, no decir "sin crédito".
  final bool customerFound;

  const CustomerCreditStanding({
    required this.creditEnabled,
    required this.creditLimit,
    required this.creditDays,
    required this.openBalance,
    this.customerFound = true,
  });

  /// null = sin límite configurado.
  double? get availableCredit {
    final limit = creditLimit;
    if (limit == null || limit <= 0) return null;
    return limit - openBalance;
  }

  bool canTake(double amount) {
    if (!creditEnabled) return false;
    final available = availableCredit;
    if (available == null) return true;
    return amount <= available + 0.01;
  }
}
