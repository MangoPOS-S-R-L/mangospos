// Step 4 del registro: método de pago (PRD-Azul-Subscriptions §8.1).
//
// Página estilo checkout: captura de tarjeta INLINE a la izquierda + resumen
// del plan a la derecha (no es un bottom sheet). Se llega acá tras crear cuenta
// + business (pending) + membership trial en Step 3, con la sesión ya activa.
//
// El resumen lee el plan del NEGOCIO recién creado vía billingStateProvider
// (membership anchor → plans, que es espejo del catálogo de MangoPOS
// Administrador), con respaldo al plan elegido en Step 1 si el estado aún no
// resuelve. Así muestra la data real, no la selección en memoria.
//
// La tarjeta se verifica con una autorización de RD$1 (Hold + Void) en la Edge
// Function `azul-tokenize-card`: solo si pasa se guarda el método y el registro
// se completa. El negocio queda `pending` → tras navegar al dashboard, el
// PendingApprovalGuard muestra "en revisión" (acceso requiere aprobación manual).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:mangopos/core/utils/app_toast.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_tokens.dart';
import '../../../data/models/billing_plan.dart';
import '../../../presentation/billing/providers/billing_providers.dart';
import '../../../presentation/billing/widgets/azul_payment_page_launcher.dart';
import '../../../services/session/session_controller.dart';
import '../widgets/auth_shell.dart';
import 'register_step1_viewmodel.dart';

class RegisterStep4View extends ConsumerWidget {
  const RegisterStep4View({super.key});

  static const _steps = <AuthShellStep>[
    AuthShellStep(title: 'Crear cuenta', complete: true),
    AuthShellStep(title: 'Agregar negocio', complete: true),
    AuthShellStep(title: 'Activación', complete: true),
    AuthShellStep(title: 'Método de pago'),
  ];

  void _onSuccess(BuildContext context) {
    AppToast.success(context, 'Tarjeta verificada. Tu cuenta está en revisión.');
    context.go(AppRoutes.dashboard);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final businessId = ref.watch(sessionProvider).activeBusinessId;

    return AuthShell(
      brandSubtitle: 'Método de pago',
      steps: _steps,
      currentStep: 3,
      main: businessId == null
          ? _sessionMissing()
          : _PaymentColumn(
              businessId: businessId,
              onSuccess: () => _onSuccess(context),
            ),
      side: _SummaryColumn(businessId: businessId),
    );
  }

  Widget _sessionMissing() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded,
              color: MangoTokens.destructive, size: 40),
          const SizedBox(height: 12),
          Text(
            'Sesión no disponible. Reinicia el registro.',
            textAlign: TextAlign.center,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 15,
              color: MangoTokens.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

/// Columna izquierda: "Selecciona tu método de pago" + tarjeta inline.
class _PaymentColumn extends StatelessWidget {
  final String businessId;
  final VoidCallback onSuccess;

  const _PaymentColumn({required this.businessId, required this.onSuccess});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Selecciona tu método de pago',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: MangoTokens.foreground,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Todas las transacciones son seguras y cifradas.',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 14,
              color: MangoTokens.mutedForeground,
            ),
          ),
          const SizedBox(height: 22),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: MangoTokens.primary, width: 1.4),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: MangoTokens.primary, width: 2),
                        ),
                        child: Center(
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: MangoTokens.primary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Tarjeta de crédito o débito',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          color: MangoTokens.foreground,
                        ),
                      ),
                      const Spacer(),
                      const _CardBrands(),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.only(left: 32),
                    child: Text(
                      'Visa, Mastercard, American Express o Discover.',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12.5,
                        color: MangoTokens.mutedForeground,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Divider(height: 1, color: MangoTokens.border),
                  ),
                  AzulPaymentPageLauncher(
                    businessId: businessId,
                    idleLabel: 'Verificar tarjeta · RD\$1',
                    onSuccess: onSuccess,
                    showSuccessToast: false,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Sin tarjeta verificada no podrás acceder al panel. No cobramos el '
            'plan durante tu prueba; hoy solo validamos la tarjeta con una '
            'autorización temporal de RD\$1 que se libera de inmediato.',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 12,
              height: 1.5,
              color: MangoTokens.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

/// Chips simples de marcas aceptadas (no usamos logos de marca por licencia).
class _CardBrands extends StatelessWidget {
  const _CardBrands();

  @override
  Widget build(BuildContext context) {
    const brands = ['VISA', 'MC', 'AMEX', 'DISC'];
    return Wrap(
      spacing: 6,
      children: brands
          .map(
            (b) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: MangoTokens.muted,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                b,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  color: MangoTokens.mutedForeground,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

/// Columna derecha: resumen del plan / cobro (estilo "Order summary").
///
/// Fuente del plan, en orden: (1) membership anchor del negocio recién creado
/// (billingStateProvider → plans, espejo de MangoPOS Administrador); (2) plan
/// elegido en Step 1 como respaldo mientras el estado del negocio resuelve.
class _SummaryColumn extends ConsumerWidget {
  final String? businessId;

  const _SummaryColumn({required this.businessId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bid = businessId;
    final billing =
        bid == null ? null : ref.watch(billingStateProvider(bid)).valueOrNull;
    final plansAsync = ref.watch(availablePlansProvider);
    final selectedPlanId = ref.watch(registerStep1VmProvider).selectedPlanId;

    // Plan: primero el del negocio (DB), si no el elegido en Step 1.
    BillingPlan? plan = billing?.plan;
    plan ??= plansAsync.maybeWhen(
      data: (plans) {
        for (final p in plans) {
          if (p.id == selectedPlanId) return p;
        }
        return null;
      },
      orElse: () => null,
    );

    final loading = plan == null &&
        (plansAsync.isLoading || (bid != null && billing == null));

    final trialDays = plan?.trialDays ?? 14;
    final planName =
        plan?.name ?? (loading ? 'Cargando…' : 'Plan seleccionado');
    final monthly = plan != null ? '${plan.formattedPrice}/mes' : '—';
    final trialEnds = billing?.trialEndsAt;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AuthSummaryCard(
            title: 'Resumen',
            children: [
              AuthSummaryRow(label: 'Plan', value: planName),
              AuthSummaryRow(label: 'Prueba gratis', value: '$trialDays días'),
              if (trialEnds != null)
                AuthSummaryRow(
                  label: 'Tu prueba termina',
                  value: _fmtDate(trialEnds),
                ),
              AuthSummaryRow(label: 'Al terminar la prueba', value: monthly),
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Divider(height: 1, color: MangoTokens.border),
              ),
              AuthSummaryRow(
                label: 'A pagar hoy',
                value: 'RD\$1.00*',
                highlight: true,
              ),
              const SizedBox(height: 4),
              Text(
                '* Autorización temporal para verificar tu tarjeta. Se libera de '
                'inmediato — no es un cobro. El primer cargo del plan ocurre al '
                'terminar la prueba de $trialDays días.',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 11.5,
                  height: 1.5,
                  color: MangoTokens.mutedForeground,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const AuthInfoCard(
            icon: Icons.verified_user_outlined,
            title: 'Procesado por Azul',
            body:
                'Tus datos viajan cifrados a Azul, el procesador local certificado '
                'de República Dominicana. Guardamos solo un token y los últimos 4 '
                'dígitos — nunca el número completo ni el CVC.',
          ),
          const SizedBox(height: 14),
          const AuthInfoCard(
            icon: Icons.timer_outlined,
            title: 'Tu prueba ya empezó',
            body:
                'Puedes cambiar de plan o cancelar cuando quieras desde '
                'Configuración → Suscripción. Sin compromiso.',
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd/$mm/${d.year}';
  }
}
