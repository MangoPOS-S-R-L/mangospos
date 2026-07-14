// Pantalla de método de pago.
//
// Registro/cambio de tarjeta vía la Payment Page de Azul (form hospedado por
// Azul, que con 3DS habilitado en el MID corre la autenticación en su página).
// Toda la mecánica de abrir el navegador + esperar la confirmación por Realtime
// vive en [AzulPaymentPageLauncher] (reusado también en el onboarding).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_colors.dart';
import '../../../data/models/billing_payment_method.dart';
import '../../../services/session/session_controller.dart';
import '../providers/billing_providers.dart';
import '../widgets/azul_payment_page_launcher.dart';
import '../widgets/pay_now_button.dart';

class PaymentMethodView extends ConsumerWidget {
  const PaymentMethodView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final businessId = session.activeBusinessId;
    if (businessId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Método de pago')),
        body: const Center(child: Text('Selecciona un negocio')),
      );
    }

    final pmAsync = ref.watch(defaultPaymentMethodProvider(businessId));
    final billingState = ref
        .watch(billingStateProvider(businessId))
        .value;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go(AppRoutes.settingsBilling),
        ),
        title: const Text(
          'Método de pago',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
      ),
      body: pmAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('No pudimos cargar la tarjeta: $e'),
          ),
        ),
        data: (pm) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (pm != null) _CardDisplay(method: pm),
            if (pm == null) const _NoCardPlaceholder(),
            if (pm != null &&
                billingState != null &&
                billingState.canAttemptCharge) ...[
              const SizedBox(height: 16),
              PayNowButton(businessId: businessId, state: billingState),
            ],
            const SizedBox(height: 16),
            AzulPaymentPageLauncher(
              businessId: businessId,
              idleLabel: pm != null ? 'Cambiar tarjeta' : 'Agregar tarjeta',
            ),
            const SizedBox(height: 18),
            const _SecurityNote(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Card display
// ---------------------------------------------------------------------------

class _CardDisplay extends StatelessWidget {
  final BillingPaymentMethod method;
  const _CardDisplay({required this.method});

  @override
  Widget build(BuildContext context) {
    final isExpired = method.isExpired;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1F2937), Color(0xFF111827)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                method.brand.toUpperCase(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
              const Spacer(),
              if (method.isDefault)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: MangoColors.primaryOrange,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'PREDETERMINADA',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(4, (i) {
              return Text(
                i < 3 ? '••••' : method.last4,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              );
            }),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              const Text(
                'VENCE',
                style: TextStyle(
                  color: Color(0xFF9CA3AF),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                method.formattedExpiration,
                style: TextStyle(
                  color: isExpired ? const Color(0xFFFCA5A5) : Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (isExpired) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEE2E2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'EXPIRADA',
                    style: TextStyle(
                      color: Color(0xFFB91C1C),
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              Text(
                'Agregada ${DateFormat('d MMM yyyy', 'es').format(method.createdAt)}',
                style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NoCardPlaceholder extends StatelessWidget {
  const _NoCardPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: MangoColors.cardBorder,
          style: BorderStyle.solid,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFFFFE6D5),
              borderRadius: BorderRadius.circular(28),
            ),
            child: const Icon(
              Icons.credit_card_off_rounded,
              color: MangoColors.primaryOrange,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Aún no has registrado una tarjeta',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                SizedBox(height: 4),
                Text(
                  'Agrega una para activar tu suscripción cuando termine el trial.',
                  style: TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SecurityNote extends StatelessWidget {
  const _SecurityNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.verified_user_outlined,
            color: MangoColors.muted,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pago procesado por Azul',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  'Tus datos de tarjeta se ingresan y procesan en la página segura '
                  'de Azul (procesador local certificado), con autenticación 3D '
                  'Secure. MangoPOS solo guarda el token y los últimos 4 dígitos.',
                  style: TextStyle(
                    fontSize: 11,
                    color: MangoColors.darkGray.withValues(alpha: 0.7),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
