import 'package:supabase_flutter/supabase_flutter.dart';

import '../datasources/queries/customers_queries.dart';

class CustomersRepository {
  final SupabaseClient _client;

  CustomersRepository(this._client);

  Future<List<Map<String, dynamic>>> getCustomers(
    String businessId, {
    String? query,
  }) async {
    var dbQuery = _client
        .from(CustomersQueries.tableCustomers)
        .select(CustomersQueries.selectBase)
        .eq('business_id', businessId);

    final normalized = query?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      final escaped = normalized.replaceAll(',', '');
      dbQuery = dbQuery.or(
        CustomersQueries.searchFields.replaceAll('{q}', escaped),
      );
    }

    final response = await dbQuery.order('name');
    return List<Map<String, dynamic>>.from(response);
  }

  Future<Map<String, dynamic>> createCustomer(Map<String, dynamic> data) async {
    final response = await _client
        .from(CustomersQueries.tableCustomers)
        .insert(data)
        .select(CustomersQueries.selectBase)
        .single();
    return Map<String, dynamic>.from(response);
  }

  Future<Map<String, dynamic>> updateCustomer(
    String id,
    Map<String, dynamic> data,
  ) async {
    final response = await _client
        .from(CustomersQueries.tableCustomers)
        .update(data)
        .eq('id', id)
        .select(CustomersQueries.selectBase)
        .single();
    return Map<String, dynamic>.from(response);
  }

  Future<void> deleteCustomer(String id) async {
    await _client.from(CustomersQueries.tableCustomers).delete().eq('id', id);
  }
}
