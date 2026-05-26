// Guard global del shell autenticado: si el comercio no tiene tarjeta
// registrada (caso edge del registro interrumpido o piloto pre-existente),
// reemplaza toda la pantalla con PaymentMethodRequiredOverlay. Libera el
// bloqueo automáticamente vía Realtime cuando llega payment_method.verified.
//
// Rutas exentas (el usuario está justamente intentando resolver el bloqueo):
//   - /register/*           — pasos del registro inicial
//   - /onboarding/*         — landing post-Azul (payment-result)
//   - /settings/billing/*   — pantallas de billing donde gestiona método de pago

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/models/billing_payment_method.dart';
import '../../../data/models/billing_state.dart';
import '../../../services/session/session_controller.dart';
import '../providers/billing_providers.dart';
import 'payment_method_required_overlay.dart';
import 'suspended_overlay.dart';

class BillingGuard extends ConsumerWidget {
  final Widget child;
  const BillingGuard({super.key, required this.child});

  static const _exemptPathPrefixes = <String>[
    '/register',
    '/onboarding',
    '/settings/billing',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final businessId = ref.watch(sessionProvider).activeBusinessId;
    if (businessId == null) return child;

    // Rutas en las que el usuario está intentando resolver el bloqueo
    // (registro o gestión de tarjeta). No mostrar overlay encima de ellas.
    final currentPath = GoRouterState.of(context).uri.path;
    if (_exemptPathPrefixes.any(currentPath.startsWith)) {
      return child;
    }

    final stateAsync = ref.watch(billingStateProvider(businessId));
    final pmAsync = ref.watch(defaultPaymentMethodProvider(businessId));

    final state = stateAsync.valueOrNull;
    // Sin info aún (loading o sin membership anchor): no bloquear para no
    // mostrar flashes de overlay durante la carga inicial.
    if (state == null) return child;

    // Suspendido: prioridad máxima. Reemplazamos con el bloqueo de suspended
    // (que ya tiene su CTA correcto a Settings → Método de pago).
    if (state.isSuspended) {
      return Scaffold(
        body: SafeArea(child: SuspendedOverlay(state: state)),
      );
    }

    // Trial sin tarjeta verificada → bloquear con overlay de "registra tarjeta".
    if (state.billingStatus == BillingStatus.trial) {
      final pm = pmAsync.valueOrNull;
      final hasVerifiedCard = pm != null &&
          pm.status == BillingPaymentMethodStatus.verified;
      if (!hasVerifiedCard) {
        return PaymentMethodRequiredOverlay(state: state);
      }
    }

    return child;
  }
}
