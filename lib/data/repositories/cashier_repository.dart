import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/payment_models.dart';

class CashierRepository {
  final SupabaseClient _client;
  CashierRepository(this._client);

  Future<List<PaymentMethod>> getPaymentMethods(String businessId) async {
    final data = await _client
        .from('payment_methods')
        .select()
        .eq('business_id', businessId)
        .eq('is_active', true)
        .order('position', ascending: true);
    return data.map((json) => PaymentMethod.fromMap(json)).toList();
  }

  Future<CashRegisterSession> requireActiveSession() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw Exception(
        'No hay sesión de caja abierta. Por favor, abre una sesión antes de procesar pagos.',
      );
    }

    final data = await _client
        .from('cash_register_sessions')
        .select()
        .eq('user_id', userId)
        .eq('status', 'open')
        .isFilter('closed_at', null)
        .maybeSingle();

    if (data == null) {
      throw Exception(
        'No hay sesión de caja abierta. Por favor, abre una sesión antes de procesar pagos.',
      );
    }

    return CashRegisterSession.fromMap(data);
  }

  Future<Map<String, dynamic>> openSession({
    required String cashRegisterId,
    required String userId,
    required double startAmount,
  }) async {
    final response = await _client.rpc(
      'fn_open_cash_session',
      params: {
        'p_cash_register_id': cashRegisterId,
        'p_user_id': userId,
        'p_start_amount': startAmount,
      },
    );
    return Map<String, dynamic>.from(response);
  }

  Future<Map<String, dynamic>> closeSession({
    required String sessionId,
    required double endAmount,
    String? notes,
  }) async {
    final response = await _client.rpc(
      'fn_close_cash_session',
      params: {
        'p_session_id': sessionId,
        'p_end_amount': endAmount,
        'p_notes': notes,
      },
    );
    return Map<String, dynamic>.from(response);
  }

  Future<Map<String, dynamic>> getSessionSummary(String sessionId) async {
    final response = await _client.rpc(
      'fn_get_cash_session_summary',
      params: {'p_session_id': sessionId},
    );
    return Map<String, dynamic>.from(response);
  }

  Future<List<Map<String, dynamic>>> getCashRegisters(String businessId) async {
    final response = await _client
        .from('cash_registers')
        .select()
        .eq('business_id', businessId)
        .eq('is_active', true);
    return List<Map<String, dynamic>>.from(response);
  }

  Future<Map<String, dynamic>> createCashRegister({
    required String businessId,
    required String name,
  }) async {
    final response = await _client
        .from('cash_registers')
        .insert({'business_id': businessId, 'name': name, 'is_active': true})
        .select()
        .single();
    return Map<String, dynamic>.from(response);
  }

  Future<Map<String, dynamic>?> getLastSession(String cashRegisterId) async {
    final response = await _client
        .from('cash_register_sessions')
        .select()
        .eq('cash_register_id', cashRegisterId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return response;
  }

  Future<CashRegisterSession?> getCurrentUserActiveSession() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;

    final data = await _client
        .from('cash_register_sessions')
        .select()
        .eq('user_id', userId)
        .eq('status', 'open')
        .isFilter('closed_at', null)
        .maybeSingle();

    if (data == null) return null;
    return CashRegisterSession.fromMap(data);
  }

  Future<List<CashRegisterSession>> getSessionsByRegister(
    String cashRegisterId, {
    int limit = 20,
  }) async {
    final data = await _client
        .from('cash_register_sessions')
        .select()
        .eq('cash_register_id', cashRegisterId)
        .order('opened_at', ascending: false)
        .limit(limit);

    return data.map((json) => CashRegisterSession.fromMap(json)).toList();
  }

  Future<List<CashTransaction>> getSessionTransactions(String sessionId) async {
    final data = await _client
        .from('cash_transactions')
        .select()
        .eq('session_id', sessionId)
        .order('created_at', ascending: false);

    return data.map((json) => CashTransaction.fromMap(json)).toList();
  }

  Future<List<Map<String, dynamic>>> getSessionPaymentsDetailed(
    String sessionId,
  ) async {
    final paymentsRaw = await _client
        .from('payments')
        .select(
          'id, order_id, check_id, payment_method_id, amount, change_amount, reference, status, session_id, created_at',
        )
        .eq('session_id', sessionId)
        .eq('status', 'completed')
        .order('created_at', ascending: false);

    final payments = List<Map<String, dynamic>>.from(paymentsRaw);
    if (payments.isEmpty) return const [];

    final methodIds = payments
        .map((p) => p['payment_method_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final orderIds = payments
        .map((p) => p['order_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final checkIds = payments
        .map((p) => p['check_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final methods = methodIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('payment_methods')
                .select('id, name, code')
                .inFilter('id', methodIds),
          );
    final methodsById = {
      for (final m in methods) m['id']?.toString() ?? '': m,
    };

    final orders = orderIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('orders')
                .select('id, session_id')
                .inFilter('id', orderIds),
          );
    final ordersById = {
      for (final o in orders) o['id']?.toString() ?? '': o,
    };

    final checks = checkIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('order_checks')
                .select('id, label, position')
                .inFilter('id', checkIds),
          );
    final checksById = {
      for (final c in checks) c['id']?.toString() ?? '': c,
    };

    final tableSessionIds = orders
        .map((o) => o['session_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final tableSessions = tableSessionIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('table_sessions')
                .select('id, customer_name, table_id')
                .inFilter('id', tableSessionIds),
          );
    final tableSessionsById = {
      for (final s in tableSessions) s['id']?.toString() ?? '': s,
    };

    final tableIds = tableSessions
        .map((s) => s['table_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final tables = tableIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('dining_tables')
                .select('id, code')
                .inFilter('id', tableIds),
          );
    final tablesById = {
      for (final t in tables) t['id']?.toString() ?? '': t,
    };

    return payments.map((payment) {
      final paymentMethodId = payment['payment_method_id']?.toString() ?? '';
      final orderId = payment['order_id']?.toString();
      final checkId = payment['check_id']?.toString();

      final method = methodsById[paymentMethodId];
      final order = orderId == null ? null : ordersById[orderId];
      final check = checkId == null ? null : checksById[checkId];
      final sessionIdForOrder = order?['session_id']?.toString();
      final tableSession = sessionIdForOrder == null
          ? null
          : tableSessionsById[sessionIdForOrder];
      final table = tableSession == null
          ? null
          : tablesById[tableSession['table_id']?.toString() ?? ''];

      return <String, dynamic>{
        ...payment,
        'method_name': method?['name'],
        'method_code': method?['code'],
        'customer_name': tableSession?['customer_name'],
        'table_code': table?['code'],
        'check_label': check?['label'],
        'check_position': check?['position'],
      };
    }).toList(growable: false);
  }

  Future<CashTransaction> createManualTransaction({
    required String sessionId,
    required double amount,
    required String type,
    String? description,
  }) async {
    final data = await _client
        .from('cash_transactions')
        .insert({
          'session_id': sessionId,
          'amount': amount,
          'type': type,
          'description': description,
        })
        .select()
        .single();

    return CashTransaction.fromMap(data);
  }
}
