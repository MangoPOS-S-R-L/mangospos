// Provider de moneda del negocio activo. Lo consume cualquier widget/viewmodel
// que necesite formatear montos — reportes, recibos, dashboards, etc.
//
// Diseño:
//   - `businessCurrencyProvider` es un FutureProvider family por business_id.
//     Carga una vez y queda cacheado mientras el usuario no salga del business.
//   - `currentBusinessCurrencyProvider` lee el business activo del session
//     controller y devuelve la moneda como AsyncValue<BusinessCurrency>.
//   - `currentBusinessCurrencyOrFallback` es una conveniencia sync: devuelve
//     DOP fallback mientras carga. Útil en ViewModels que no pueden ser async.
//
// Fallback policy: si la query falla (BD apagada, RLS bloqueada, columna
// no existe aún por migration pendiente) devolvemos `BusinessCurrency.fallbackDop`
// en vez de propagar el error — el reporte sigue funcionando con `RD$`
// como antes, y el error queda en logs para diagnóstico.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/session/session_controller.dart';
import 'business_currency.dart';

/// Moneda configurada para un business_id específico. Lazy: la primera lectura
/// dispara la query; lecturas subsecuentes hit cache hasta invalidación.
final businessCurrencyProvider =
    FutureProvider.family<BusinessCurrency, String>((ref, businessId) async {
  try {
    final row = await Supabase.instance.client
        .from('business_settings')
        .select('currency_code')
        .eq('business_id', businessId)
        .maybeSingle();
    final code = (row?['currency_code'] as String?)?.trim();
    return BusinessCurrency.fromCode(code);
  } catch (e) {
    // Migration pendiente, RLS, network — no debería romper el UI.
    if (kDebugMode) {
      // ignore: avoid_print
      print('[currency] fallback DOP por error: $e');
    }
    return BusinessCurrency.fallbackDop;
  }
});

/// Moneda del business actualmente activo en la sesión. Re-emite cuando el
/// usuario cambia de business (multi-tenancy).
final currentBusinessCurrencyProvider =
    Provider<AsyncValue<BusinessCurrency>>((ref) {
  final businessId = ref.watch(sessionProvider).activeBusinessId;
  if (businessId == null || businessId.isEmpty) {
    return const AsyncValue.data(BusinessCurrency.fallbackDop);
  }
  return ref.watch(businessCurrencyProvider(businessId));
});

/// Versión "garantizada" para callers sync que no pueden esperar el async.
/// Devuelve la moneda real si ya está cargada, o DOP fallback mientras carga.
/// Para reportes esto es lo que típicamente querés: el UI nunca queda en
/// blanco esperando la moneda.
BusinessCurrency currentBusinessCurrencyOrFallback(WidgetRef ref) {
  return ref
      .watch(currentBusinessCurrencyProvider)
      .maybeWhen(data: (c) => c, orElse: () => BusinessCurrency.fallbackDop);
}

/// Versión `Ref` (para StateNotifier / Notifier) — equivalente a la de arriba
/// pero usa `read` en vez de `watch` (sync, sin re-build).
BusinessCurrency currentBusinessCurrencyOrFallbackRef(Ref ref) {
  return ref
      .read(currentBusinessCurrencyProvider)
      .maybeWhen(data: (c) => c, orElse: () => BusinessCurrency.fallbackDop);
}
