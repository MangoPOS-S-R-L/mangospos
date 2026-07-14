// Providers Riverpod para el módulo billing.
//
// Convención:
//   - Read providers son family por business_id explícito (no asumimos session
//     desde acá — la UI los watcha pasando el id que viene de sessionProvider).
//   - Streams para datos que cambian en tiempo real (billing state, default
//     payment method) — la UI reacciona cuando el callback de Azul inserta
//     una tarjeta o el cron marca un cobro.
//   - Futures para datos que no cambian frecuentemente (catálogo de planes,
//     histórico de cobros que se refresca por pull-to-refresh).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../data/models/billing_charge.dart';
import '../../../data/models/billing_payment_method.dart';
import '../../../data/models/billing_plan.dart';
import '../../../data/models/billing_state.dart';
import '../../../data/repositories/billing_repository.dart';

/// Catálogo de planes activos. Se cachea por toda la sesión (rara vez cambia).
/// Source of truth: tabla `plans`, que es espejo de `plan_catalog` (panel admin)
/// vía el trigger de la migración 20260602_0003.
final availablePlansProvider = FutureProvider<List<BillingPlan>>((ref) {
  final repo = ref.watch(billingRepositoryProvider);
  return repo.listAvailablePlans();
});

/// Planes seleccionables en el REGISTRO/onboarding: solo planes de pago.
/// Excluye trial/free (precio 0), que existen en el catálogo para billing pero
/// no son opciones elegibles en el signup (el trial se aplica como periodo, no
/// como plan a elegir). Derivado de [availablePlansProvider].
final signupPlansProvider = FutureProvider<List<BillingPlan>>((ref) async {
  final plans = await ref.watch(availablePlansProvider.future);
  return plans
      .where((p) => p.priceCentsMonthly > 0)
      .toList(growable: false);
});

/// Estado billing del business (membership anchor + plan + último charge).
/// Re-emite cuando cualquier columna de la membership cambia.
final billingStateProvider =
    StreamProvider.family<BillingState?, String>((ref, businessId) {
  final repo = ref.watch(billingRepositoryProvider);
  return repo.watchBillingStateForBusiness(businessId);
});

/// Método de pago default del business. Re-emite cuando se cambia tarjeta.
final defaultPaymentMethodProvider =
    StreamProvider.family<BillingPaymentMethod?, String>((ref, businessId) {
  final repo = ref.watch(billingRepositoryProvider);
  return repo.watchDefaultPaymentMethod(businessId);
});

/// Histórico de cobros (últimos 24 por default). Refresca al hacer
/// `ref.invalidate(chargesProvider(businessId))`.
final chargesProvider =
    FutureProvider.family<List<BillingCharge>, String>((ref, businessId) {
  final repo = ref.watch(billingRepositoryProvider);
  return repo.listCharges(businessId);
});
