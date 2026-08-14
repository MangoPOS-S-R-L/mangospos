// Guard global del shell autenticado: bloquea el acceso al POS si la cuenta
// no tiene tarjeta verificada (caso edge del registro interrumpido o piloto
// pre-existente) o si está suspendida. Libera automáticamente vía Realtime
// cuando llega payment_method.status='verified'.
//
// Rutas exentas (donde el usuario está justamente intentando resolver):
//   - /register/*           — pasos del registro inicial
//   - /onboarding/*         — landing post-Azul (payment-result)
//   - /settings/billing/*   — pantallas de billing donde registra método de pago
//
// Loading strategy: durante el primer fetch del billing state mostramos un
// loading screen branded en lugar del shell vacío. Eso elimina el flash que
// permitía ver el dashboard por 1 seg antes de que apareciera el overlay.
// `skipLoadingOnRefresh: true` evita que re-emisiones del stream Realtime
// disparen un loading nuevo (usamos el valor cacheado).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/mango_colors.dart';
import '../../../data/models/billing_payment_method.dart';
import '../../../data/models/billing_state.dart';
import '../../../services/session/session_controller.dart';
import '../providers/billing_providers.dart';
import 'payment_method_required_overlay.dart';
import 'suspended_overlay.dart';
import '../../../core/theme/app_colors.dart';

class BillingGuard extends ConsumerWidget {
  final Widget child;
  const BillingGuard({super.key, required this.child});

  static const _exemptPathPrefixes = <String>[
    '/register',
    '/onboarding',
    '/settings/billing',
  ];

  /// TEMPORAL — desactivado mientras Azul no whitelistee nuestra IP en
  /// Incapsula y no podamos tokenizar tarjetas. Cuando volvamos a tener
  /// pagos funcionando, poner en `true` y este guard vuelve a bloquear el
  /// shell para cuentas en trial sin tarjeta + cuentas suspendidas.
  /// Ver memory/project_azul_incapsula_blocker.md.
  static const bool _kEnabled = false;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_kEnabled) return child;

    final businessId = ref.watch(sessionProvider).activeBusinessId;
    if (businessId == null) return child;

    // Rutas en las que el usuario está intentando resolver el bloqueo
    // (registro o gestión de tarjeta). No mostrar overlay encima de ellas.
    final currentPath = GoRouterState.of(context).uri.path;
    if (_exemptPathPrefixes.any(currentPath.startsWith)) {
      return child;
    }

    final stateAsync = ref.watch(billingStateProvider(businessId));

    return stateAsync.when(
      skipLoadingOnRefresh: true,
      // Primer fetch: mostramos loading screen branded (en vez de child) para
      // evitar el flash de dashboard antes de que aparezca el overlay.
      loading: () => const _BillingBootstrapLoading(),
      // Si la query falla, no bloqueamos — mejor dejar entrar que dejar al
      // usuario varado. El error queda en logs; el cron eventualmente
      // detectará inconsistencia.
      error: (_, _) => child,
      data: (state) {
        // Sin membership anchor: no aplicar guard (es un usuario sin business
        // o caso edge).
        if (state == null) return child;

        // Suspendido: prioridad máxima.
        if (state.isSuspended) {
          return Scaffold(
            backgroundColor: AppColors.background,
            body: SafeArea(child: SuspendedOverlay(state: state)),
          );
        }

        // Trial sin tarjeta verificada → overlay "Registra tu tarjeta".
        // Verificamos el PM en su propio AsyncValue para no mostrar overlay
        // antes de saber si tiene tarjeta o no.
        if (state.billingStatus == BillingStatus.trial) {
          final pmAsync = ref.watch(defaultPaymentMethodProvider(businessId));
          return pmAsync.when(
            skipLoadingOnRefresh: true,
            loading: () => const _BillingBootstrapLoading(),
            error: (_, _) => child,
            data: (pm) {
              final hasVerifiedCard = pm != null &&
                  pm.status == BillingPaymentMethodStatus.verified;
              if (hasVerifiedCard) return child;
              return PaymentMethodRequiredOverlay(state: state);
            },
          );
        }

        return child;
      },
    );
  }
}

/// Splash de transición mientras cargamos el estado de billing por primera
/// vez. Diseño consistente con el branding (color primario + spinner sutil).
/// Duración esperada: ~300-800ms en producción.
class _BillingBootstrapLoading extends StatelessWidget {
  const _BillingBootstrapLoading();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: MangoColors.primaryOrange,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: MangoColors.primaryOrange.withValues(alpha: 0.22),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(
                Icons.point_of_sale_rounded,
                color: MangoColors.white,
                size: 32,
              ),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: MangoColors.primaryOrange,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Preparando tu cuenta…',
              style: TextStyle(
                fontSize: 13,
                color: MangoColors.muted,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
