// Repositorio del modo multimesero. Encapsula:
//   - Lectura del toggle `business_settings.multimesero_enabled`
//   - Verificación de PIN contra `fn_verify_employee_pin`
//   - Update del toggle desde la UI de settings
//
// El repo NO mantiene estado — el state vive en `ActiveWaiterController`.
// Acá solo van I/O y mapeos.

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

    return ActiveWaiter(
      employeeId: employeeId,
      firstName: firstName,
      lastName: map['last_name']?.toString(),
      businessId: map['business_id']?.toString() ?? businessId,
      validatedAt: DateTime.now(),
    );
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
