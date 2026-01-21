import 'package:supabase_flutter/supabase_flutter.dart';

class CustomersRepository {
  final SupabaseClient _client;

  CustomersRepository(this._client);

  Future<List<Map<String, dynamic>>> getCustomers(
    String businessId, {
    String? query,
  }) async {
    // Start building the query
    // Filters must be applied BEFORE modifiers like order()
    var dbQuery = _client
        .from('customers')
        .select()
        .eq('business_id', businessId);

    if (query != null && query.isNotEmpty) {
      dbQuery = dbQuery.ilike('name', '%$query%');
    }

    // Apply order and await
    final response = await dbQuery.order('name');

    return List<Map<String, dynamic>>.from(response);
  }

  Future<Map<String, dynamic>> createCustomer(Map<String, dynamic> data) async {
    final response = await _client
        .from('customers')
        .insert(data)
        .select()
        .single();
    return Map<String, dynamic>.from(response);
  }

  Future<Map<String, dynamic>> updateCustomer(
    String id,
    Map<String, dynamic> data,
  ) async {
    final response = await _client
        .from('customers')
        .update(data)
        .eq('id', id)
        .select()
        .single();
    return Map<String, dynamic>.from(response);
  }

  Future<void> deleteCustomer(String id) async {
    await _client.from('customers').delete().eq('id', id);
  }
}
