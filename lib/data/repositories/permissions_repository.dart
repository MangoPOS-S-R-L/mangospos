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
    // Asegurar que existan los códigos en el catálogo. Si la policy de
    // INSERT no permite (RLS) o el usuario no es admin, el upsert falla
    // silenciosamente — capturamos la excepción para que NO bloquee el
    // guardado de overrides (el SELECT de abajo nos dirá qué falta).
    if (codes.isNotEmpty) {
      final toUpsert = codes
          .map((c) => {'code': c, 'name': c, 'module': c.split('.').first})
          .toList();
      try {
        await _client.from('permissions').upsert(toUpsert, onConflict: 'code');
      } catch (e) {
        // Solo log; no abortamos el flujo. Si los códigos ya existían
        // (caso normal post-backfill), no hace falta el upsert.
        // ignore: avoid_print
        print('[permissions] upsert advertencia: $e');
      }
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

    final foundCodes = (perms as List)
        .map((p) => (p as Map<String, dynamic>)['code']?.toString())
        .whereType<String>()
        .toSet();

    // Si algún código del catálogo Dart no existe en la tabla `permissions`
    // de la DB, antes se descartaba silencioso → el override no se guardaba
    // y el usuario percibía "los permisos no se guardan". Ahora levantamos
    // un error claro para que el caller muestre un snackbar útil y nadie
    // pierda overrides sin saber por qué.
    final missing = codes.difference(foundCodes);
    if (missing.isNotEmpty) {
      throw StateError(
        'Códigos de permiso no encontrados en el catálogo de la BD: '
        '${missing.join(", ")}. '
        'Aplicá la migration 20260515_0002 o agregalos manualmente a la '
        'tabla `public.permissions`.',
      );
    }

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
