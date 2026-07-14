// Modelo de negocio derivado: ¿este negocio opera como RESTAURANTE o como
// RETAIL? Un único source of truth para ramificar UI/lógica en toda la app
// (PRD extensión Retail).
//
// Señal autoritativa: `businesses.business_type`. Si el tipo es un vertical
// retail conocido → retail; cualquier otro tipo conocido → restaurante. Para
// 'Otro'/null/desconocido caemos a la operación real (feature flags): sin mesas
// y sin cocina = retail. Así un negocio viejo sin tipo claro se clasifica por
// cómo está configurado, no por un default arbitrario.
//
// Diseño de providers espejado de business_currency_provider.dart:
//   - businessTypeProvider: FutureProvider family por business_id (cachea).
//   - currentBusinessModelProvider: combina tipo + flags del negocio activo.
//   - ref.watchBusinessModel(): helper sync con default seguro (restaurante)
//     mientras carga — el comportamiento legacy es el de restaurante completo.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/repositories/pos_settings_repository.dart';
import '../../services/session/session_controller.dart';
import 'business_features_provider.dart';
import 'retail_profile_defaults.dart';

enum BusinessModel {
  restaurant,
  retail;

  bool get isRetail => this == BusinessModel.retail;
  bool get isRestaurant => this == BusinessModel.restaurant;

  String get label => isRetail ? 'Retail' : 'Restaurante';
}

/// Clasifica el modelo a partir de los parámetros que tenemos. Función pura:
/// úsala donde ya tengas `businessType` y `features` (registro, tests, etc.).
///
/// Prioridad:
///   1. Tipo retail conocido → retail.
///   2. Cualquier otro tipo conocido (no retail, no null, no 'Otro') →
///      restaurante.
///   3. 'Otro'/null/desconocido → inferir de la operación: sin mesas y sin
///      cocina = retail; en otro caso restaurante.
BusinessModel resolveBusinessModel({
  required String? businessType,
  required BusinessFeatures features,
}) {
  if (RetailProfileDefaults.isRetail(businessType)) {
    return BusinessModel.retail;
  }
  final type = businessType?.trim();
  final isAmbiguous = type == null || type.isEmpty || type == 'Otro';
  if (!isAmbiguous) {
    // Tipo conocido y no-retail = restaurante (Restaurante, Comida Rapida,
    // Bar/Lounge, Cafeteria, etc.).
    return BusinessModel.restaurant;
  }
  // Tipo ambiguo: deja que la configuración real decida.
  final operatesAsRetail =
      !features.salesModeTableEnabled && !features.kitchenEnabled;
  return operatesAsRetail ? BusinessModel.retail : BusinessModel.restaurant;
}

/// `business_type` de un business_id. Lazy + cacheado. Fallback `null` ante
/// error (BD/RLS/migración) — el modelo cae a inferencia por flags.
final businessTypeProvider =
    FutureProvider.family<String?, String>((ref, businessId) async {
  try {
    final row = await Supabase.instance.client
        .from('businesses')
        .select('business_type')
        .eq('id', businessId)
        .maybeSingle();
    return (row?['business_type'] as String?)?.trim();
  } catch (e) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[business_model] business_type fallback null por error: $e');
    }
    return null;
  }
});

/// `business_type` del negocio activo en sesión.
final currentBusinessTypeProvider = Provider<AsyncValue<String?>>((ref) {
  final businessId = ref.watch(sessionProvider).activeBusinessId;
  if (businessId == null || businessId.isEmpty) {
    return const AsyncValue.data(null);
  }
  return ref.watch(businessTypeProvider(businessId));
});

/// Modelo del negocio activo. Combina tipo + flags. Mientras cargan, default
/// seguro = restaurante (features completas), igual que el legacy.
final currentBusinessModelProvider = Provider<BusinessModel>((ref) {
  final businessType = ref.watch(currentBusinessTypeProvider).value;
  final features =
      ref.watch(businessFeaturesProvider).value ?? BusinessFeatures.defaults;
  return resolveBusinessModel(businessType: businessType, features: features);
});

/// Helpers sync para call sites que no quieren manejar AsyncValue. Devuelven el
/// modelo ya resuelto (o restaurante mientras carga).
extension BusinessModelRefExt on WidgetRef {
  BusinessModel watchBusinessModel() => watch(currentBusinessModelProvider);
  BusinessModel readBusinessModel() => read(currentBusinessModelProvider);
}

/// Versión `Ref` (StateNotifier/Notifier).
BusinessModel readBusinessModelRef(Ref ref) =>
    ref.read(currentBusinessModelProvider);
