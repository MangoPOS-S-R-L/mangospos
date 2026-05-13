// Feature flags por negocio — provider global.
//
// Carga `BusinessFeatures` del negocio activo (vía sessionProvider) y
// lo cachea. Cuando cambia el business activo (multi-tenant: dueño que
// alterna entre sucursales), el provider re-evalúa.
//
// Uso típico:
//   final features = ref.watch(businessFeaturesProvider).value
//       ?? BusinessFeatures.defaults;
//   if (features.kitchenEnabled) { ... }
//
// Pattern AsyncValue para que la UI pueda mostrar loading / fallback.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/pos_settings_repository.dart';
import '../../services/session/session_controller.dart';

/// Stream que re-emite cuando cambia el business activo. La carga real
/// vive en [posSettingsRepositoryProvider]. El AsyncValue resultante
/// puede estar en loading mientras se hace la primera query.
final businessFeaturesProvider = FutureProvider<BusinessFeatures>((ref) async {
  final session = ref.watch(sessionProvider);
  final businessId = session.activeBusinessId;
  if (businessId == null || businessId.isEmpty) {
    return BusinessFeatures.defaults;
  }
  final repo = ref.read(posSettingsRepositoryProvider);
  return repo.getBusinessFeatures(businessId);
});

/// Helper síncrono para call sites que no quieren manejar AsyncValue:
/// devuelve los flags cargados o defaults si aún no llegó la respuesta.
/// Útil dentro de `build()` cuando preferimos comportamiento legacy
/// (todo prendido) sobre un spinner.
extension BusinessFeaturesRefExt on WidgetRef {
  BusinessFeatures readBusinessFeatures() {
    final async = read(businessFeaturesProvider);
    return async.value ?? BusinessFeatures.defaults;
  }

  BusinessFeatures watchBusinessFeatures() {
    final async = watch(businessFeaturesProvider);
    return async.value ?? BusinessFeatures.defaults;
  }
}
