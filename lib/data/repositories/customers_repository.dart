import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/network/connectivity_service.dart';
import '../../core/offline/customers_offline_cache.dart';
import '../../core/offline/offline_pos_service.dart';
import '../datasources/queries/customers_queries.dart';

class CustomersRepository {
  final SupabaseClient _client;

  CustomersRepository(this._client);

  /// Clientes del negocio. Sin red (o si la consulta falla por red) sale de
  /// la última lista guardada en este equipo, filtrada localmente, en vez
  /// de esperar el timeout y devolver nada.
  Future<List<Map<String, dynamic>>> getCustomers(
    String businessId, {
    String? query,
  }) async {
    final normalized = query?.trim() ?? '';
    final cache = CustomersOfflineCache.instance;
    Future<List<Map<String, dynamic>>> fromCache() async =>
        CustomersOfflineCache.filter(await cache.load(businessId), normalized);

    if (!ConnectivityService().isConnected) return fromCache();

    try {
      final rows = await _fetchCustomers(
        businessId,
        normalized,
      ).timeout(const Duration(seconds: 5));
      // Solo la lista completa es la foto a guardar; una búsqueda no.
      if (normalized.isEmpty) unawaited(cache.save(businessId, rows));
      return rows;
    } catch (e) {
      if (e is! TimeoutException && !OfflinePosService.isTransportError(e)) {
        rethrow;
      }
      ConnectivityService().reportTransportFailure();
      return fromCache();
    }
  }

  Future<List<Map<String, dynamic>>> _fetchCustomers(
    String businessId,
    String normalized,
  ) async {
    var dbQuery = _client
        .from(CustomersQueries.tableCustomers)
        .select(CustomersQueries.selectBase)
        .eq('business_id', businessId);

    if (normalized.isNotEmpty) {
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
