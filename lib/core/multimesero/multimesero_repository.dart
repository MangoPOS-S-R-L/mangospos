// Repositorio del modo multimesero. Encapsula:
//   - Lectura del toggle `business_settings.multimesero_enabled`
//   - Verificación de PIN contra `fn_verify_employee_pin`
//   - Update del toggle desde la UI de settings
//
// El repo NO mantiene estado — el state vive en `ActiveWaiterController`.
// Acá solo van I/O y mapeos.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'active_waiter_provider.dart';

class MultimeseroRepository {
  MultimeseroRepository(this._client);

  final SupabaseClient _client;

  /// Lee el toggle `multimesero_enabled` del business. Devuelve `false` si
  /// no hay fila en `business_settings` (default seguro).
  Future<bool> isEnabled(String businessId) async {
    if (businessId.isEmpty) return false;
    final row = await _client
        .from('business_settings')
        .select('multimesero_enabled')
        .eq('business_id', businessId)
        .maybeSingle();
    final value = row?['multimesero_enabled'];
    return value is bool ? value : false;
  }

  /// Actualiza el toggle. Solo callable por owner/admin del business
  /// (validado por RLS de `business_settings`).
  Future<void> setEnabled({
    required String businessId,
    required bool enabled,
  }) async {
    await _client
        .from('business_settings')
        .upsert(
          {
            'business_id': businessId,
            'multimesero_enabled': enabled,
          },
          onConflict: 'business_id',
        );
  }

  /// Verifica un PIN. Devuelve `ActiveWaiter` si es válido o `null` si no
  /// hay match. La RPC valida que el caller pertenezca al business antes
  /// de buscar, así que un usuario no puede sondear PINs de otro negocio.
  ///
  /// Throws `PostgrestException` si el caller NO pertenece al business
  /// (mensaje `UNAUTHORIZED_BUSINESS`).
  Future<ActiveWaiter?> verifyPin({
    required String businessId,
    required String pin,
  }) async {
    final trimmed = pin.trim();
    if (trimmed.isEmpty || businessId.isEmpty) return null;

    final response = await _client.rpc(
      'fn_verify_employee_pin',
      params: {
        'p_business_id': businessId,
        'p_pin': trimmed,
      },
    );

    if (response == null) return null;
    if (response is! Map) return null;
    final map = Map<String, dynamic>.from(response);
    final employeeId = map['employee_id']?.toString();
    final firstName = map['first_name']?.toString();
    if (employeeId == null || employeeId.isEmpty || firstName == null) {
      return null;
    }

    final resolvedBusinessId = map['business_id']?.toString() ?? businessId;
    final userId = map['user_id']?.toString();

    return ActiveWaiter(
      employeeId: employeeId,
      firstName: firstName,
      lastName: map['last_name']?.toString(),
      businessId: resolvedBusinessId,
      validatedAt: DateTime.now(),
      userId: userId,
      permissions: await _loadWaiterPermissions(
        userId: userId,
        businessId: resolvedBusinessId,
      ),
    );
  }

  /// Permisos efectivos del mesero que acaba de identificarse.
  ///
  /// Sin esto, los gates de mesa evaluaban los permisos del usuario logueado
  /// en el dispositivo, no los del mesero que metió su PIN: en una tablet
  /// compartida, el mesero A prestaba (o negaba) sus permisos a todos.
  ///
  /// Best-effort a propósito. Devuelve `null` ante cualquier tropiezo — sin
  /// login, sin red, RPC vacío — y en ese caso el caller sigue usando los
  /// permisos de la sesión. Nunca dejamos a un mesero sin poder trabajar
  /// porque una lectura falló.
  ///
  /// El RLS de `user_permission_overrides` y `user_roles` es por negocio
  /// (`fn_user_in_business`), no por `user_id`, así que un mesero puede
  /// resolver los permisos de otro del mismo negocio sin privilegios extra.
  Future<Set<String>?> _loadWaiterPermissions({
    required String? userId,
    required String businessId,
  }) async {
    if (userId == null || userId.isEmpty || businessId.isEmpty) return null;
    try {
      final response = await _client.rpc(
        'fn_user_effective_permissions',
        params: {'p_user_id': userId, 'p_business_id': businessId},
      ).timeout(const Duration(seconds: 4));

      if (response is! List) return null;
      final granted = response
          .where((row) =>
              row is Map<String, dynamic> &&
              row['allowed'] == true &&
              row['code'] != null)
          .map((row) => (row as Map<String, dynamic>)['code'].toString())
          .where((code) => code.isNotEmpty)
          .toSet();

      // Vacío = no confiable (RBAC sin sembrar, respuesta parcial). Preferimos
      // el fallback a la sesión antes que bloquear al mesero.
      return granted.isEmpty ? null : granted;
    } catch (e) {
      debugPrint('[multimesero] permisos del mesero no resueltos: $e');
      return null;
    }
  }
}

final multimeseroRepositoryProvider = Provider<MultimeseroRepository>(
  (ref) => MultimeseroRepository(Supabase.instance.client),
);

/// Provider asíncrono del toggle del business activo. La UI puede hacer
/// `ref.watch(multimeseroEnabledProvider(businessId))` para reactivar
/// vistas cuando el admin lo prende/apaga.
final multimeseroEnabledProvider =
    FutureProvider.family<bool, String>((ref, businessId) async {
  final repo = ref.read(multimeseroRepositoryProvider);
  return repo.isEnabled(businessId);
});
