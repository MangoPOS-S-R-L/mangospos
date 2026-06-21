// Add-ons activados por plataforma — provider global.
//
// Carga el set de módulos extra ACTIVOS para el negocio activo (vía
// sessionProvider). El shell hace `ref.watch` para mostrar/ocultar destinos
// gateados por `requiresModule`. Default `{}` mientras carga o si falla: un
// add-on de pago NO se muestra hasta confirmar que está activo.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/repositories/business_modules_repository.dart';
import '../../services/session/session_controller.dart';

final businessModulesRepositoryProvider =
    Provider<BusinessModulesRepository>(
  (ref) => BusinessModulesRepository(Supabase.instance.client),
);

/// Set de claves de módulos activos del negocio activo. Re-evalúa cuando
/// cambia el business (multi-tenant).
final enabledModulesProvider = FutureProvider<Set<String>>((ref) async {
  final session = ref.watch(sessionProvider);
  final businessId = session.activeBusinessId;
  if (businessId == null || businessId.isEmpty) {
    return const <String>{};
  }
  final repo = ref.read(businessModulesRepositoryProvider);
  return repo.fetchEnabled(businessId);
});

/// Helpers síncronos para call sites del shell que prefieren no manejar
/// AsyncValue: devuelven el set cargado o `{}` (oculto) si aún no llegó.
extension EnabledModulesRefExt on WidgetRef {
  Set<String> readEnabledModules() {
    final async = read(enabledModulesProvider);
    return async.value ?? const <String>{};
  }

  Set<String> watchEnabledModules() {
    final async = watch(enabledModulesProvider);
    return async.value ?? const <String>{};
  }
}
