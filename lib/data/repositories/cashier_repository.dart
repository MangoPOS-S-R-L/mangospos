import 'package:supabase_flutter/supabase_flutter.dart';

class CashierRepository {
  final SupabaseClient _client;
  CashierRepository(this._client);

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
}
