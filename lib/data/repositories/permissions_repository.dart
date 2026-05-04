import 'package:supabase_flutter/supabase_flutter.dart';

class PermissionsRepository {
  final SupabaseClient _client;
  PermissionsRepository(this._client);

  Future<Set<String>> fetchEffectivePermissions({
    required String businessId,
    required String userId,
  }) async {
    final res = await _client.rpc(
      'fn_user_effective_permissions',
      params: {'p_user_id': userId, 'p_business_id': businessId},
    );
    if (res == null) return {};
    final list = (res as List)
        .where((row) => row['allowed'] == true)
        .map((row) => row['code'] as String)
        .toSet();
    return list;
  }

  Future<void> saveUserOverrides({
    required String businessId,
    required String userId,
    required String employeeId,
    required Set<String> codes,
  }) async {
    // Nos aseguramos que existan los permisos
    if (codes.isNotEmpty) {
      final toUpsert = codes
          .map((c) => {'code': c, 'name': c, 'module': c.split('.').first})
          .toList();
      await _client.from('permissions').upsert(toUpsert, onConflict: 'code');
    }

    // Limpiar overrides previos del usuario para este negocio
    await _client
        .from('user_permission_overrides')
        .delete()
        .eq('user_id', userId)
        .eq('business_id', businessId);

    if (codes.isEmpty) return;

    // Buscar los IDs de permisos
    final perms = await _client
        .from('permissions')
        .select('id, code')
        .inFilter('code', codes.toList());

    final rows = (perms as List)
        .map(
          (p) => {
            'user_id': userId,
            'employee_id': employeeId,
            'permission_id': p['id'],
            'business_id': businessId,
            'allow': true,
          },
        )
        .toList();

    await _client.from('user_permission_overrides').insert(rows);
  }
}
