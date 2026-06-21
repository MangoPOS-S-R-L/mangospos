import 'package:supabase_flutter/supabase_flutter.dart';

/// Claves de add-ons (módulos extra activados por la plataforma desde el panel
/// administrativo). Una clave aquí = una fila potencial en `business_modules`.
class BusinessModuleKeys {
  static const reservations = 'reservations';
}

/// Lee los entitlements de add-ons del negocio desde `business_modules`. El
/// negocio solo PUEDE leer (RLS); la activación la hace la plataforma con
/// service_role. Si la tabla aún no existe o la query falla, devuelve vacío
/// (= ningún add-on activo), que es el comportamiento seguro por defecto: un
/// módulo de pago no aparece hasta que se confirme activado.
class BusinessModulesRepository {
  final SupabaseClient _client;

  BusinessModulesRepository(this._client);

  /// Conjunto de claves de módulos ACTIVOS para el negocio.
  Future<Set<String>> fetchEnabled(String businessId) async {
    if (businessId.isEmpty) return const <String>{};
    try {
      final rows = await _client
          .from('business_modules')
          .select('module, enabled')
          .eq('business_id', businessId)
          .eq('enabled', true);
      return List<Map<String, dynamic>>.from(rows)
          .map((r) => r['module'] as String)
          .toSet();
    } catch (_) {
      return const <String>{};
    }
  }

  /// Helper directo: ¿está activo [module] para el negocio?
  Future<bool> isEnabled(String businessId, String module) async {
    final set = await fetchEnabled(businessId);
    return set.contains(module);
  }
}
