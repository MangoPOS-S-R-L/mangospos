// Hub central del módulo billing — Settings → Suscripción y pagos.
//
// Muestra: plan actual, status, trial/next billing countdown, último cobro,
// y acceso a las sub-pantallas (cambio de plan, método de pago, histórico).
// Si billing_status='suspended' muestra el SuspendedOverlay bloqueante.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_colors.dart';
import '../../../data/models/billing_state.dart';
import '../../../services/session/session_controller.dart';
import '../providers/billing_providers.dart';
import '../widgets/pay_now_button.dart';
import '../widgets/suspended_overlay.dart';

class MySubscriptionView extends ConsumerWidget {
  const MySubscriptionView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final businessId = session.activeBusinessId;

    if (businessId == null) {
      return const _NoBusinessScaffold();
    }

    final stateAsync = ref.watch(billingStateProvider(businessId));
    final paymentMethodAsync = ref.watch(
      defaultPaymentMethodProvider(businessId),
    );

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        titleSpacing: 12,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: const Text(
          'Suscripción y pagos',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
      ),
      body: stateAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorPanel(message: e.toString()),
        data: (state) {
          if (state == null) {
            return const _NotSetUpPanel();
          }
          if (state.isSuspended) {
            return SuspendedOverlay(state: state);
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(billingStateProvider(businessId));
              ref.invalidate(defaultPaymentMethodProvider(businessId));
              ref.invalidate(chargesProvider(businessId));
              await Future<void>.delayed(const Duration(milliseconds: 250));
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _PlanStatusCard(state: state),
                const SizedBox(height: 12),
                if (state.billingStatus == BillingStatus.trial)
                  _TrialCountdownCard(state: state)
                else
                  _NextBillingCard(state: state),
                const SizedBox(height: 12),
                _PaymentMethodSummary(
                  paymentMethod: paymentMethodAsync.valueOrNull,
                ),
                if (paymentMethodAsync.valueOrNull != null &&
                    state.canAttemptCharge) ...[
                  const SizedBox(height: 12),
                  PayNowButton(businessId: businessId, state: state),
                ],
                const SizedBox(height: 12),
                _LastChargeCard(state: state),
                const SizedBox(height: 20),
                _ActionsList(state: state),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

class _PlanStatusCard extends StatelessWidget {
  final BillingState state;
  const _PlanStatusCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final plan = state.plan;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plan?.name ?? 'Sin plan asignado',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    if (plan != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${plan.formattedPrice} / mes',
                        style: const TextStyle(
                          fontSize: 13,
                          color: MangoColors.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _StatusBadge(status: state.billingStatus),
            ],
          ),
          if (plan?.description != null) ...[
            const SizedBox(height: 10),
            Text(
              plan!.description!,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF60646C),
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TrialCountdownCard extends StatelessWidget {
  final BillingState state;
  const _TrialCountdownCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final days = state.trialDaysRemaining;
    final endsAt = state.trialEndsAt;
    final formatter = DateFormat("d 'de' MMMM yyyy", 'es');

    String headline;
    Color accent;
    if (days == null || endsAt == null) {
      headline = 'Período de prueba';
      accent = MangoColors.infoBlue;
    } else if (days < 0) {
      headline = 'Tu período de prueba terminó';
      accent = const Color(0xFFEAB308);
    } else if (days == 0) {
      headline = 'Tu prueba termina hoy';
      accent = const Color(0xFFEAB308);
    } else {
      headline = days == 1
          ? 'Falta 1 día de prueba'
          : 'Faltan $days días de prueba';
      accent = MangoColors.infoBlue;
    }

    return _Card(
      accentColor: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.timer_outlined, color: accent, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headline,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
                ),
              ),
            ],
          ),
          if (endsAt != null) ...[
            const SizedBox(height: 6),
            Text(
              'Hasta el ${formatter.format(endsAt)}',
              style: const TextStyle(fontSize: 13, color: MangoColors.muted),
            ),
          ],
          if (state.nextBillingDate != null) ...[
            const SizedBox(height: 8),
            Text(
              'Primer cobro: ${formatter.format(state.nextBillingDate!)}'
              '${state.plan != null ? ' · ${state.plan!.formattedPrice}' : ''}',
              style: const TextStyle(
                fontSize: 13,
                color: MangoColors.darkGray,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NextBillingCard extends StatelessWidget {
  final BillingState state;
  const _NextBillingCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final next = state.nextBillingDate;
    final days = state.daysUntilNextBilling;
    final formatter = DateFormat("d 'de' MMMM yyyy", 'es');

    final String headline;
    final Color accent;
    if (state.billingStatus == BillingStatus.pastDue) {
      headline = 'Pago pendiente';
      accent = const Color(0xFFEAB308);
    } else if (next == null) {
      headline = 'Próximo cobro';
      accent = MangoColors.muted;
    } else if (days == null) {
      headline = 'Próximo cobro';
      accent = MangoColors.successGreen;
    } else if (days <= 0) {
      headline = 'Cobro programado hoy';
      accent = MangoColors.primaryOrange;
    } else if (days <= 3) {
      headline = days == 1
          ? 'Próximo cobro mañana'
          : 'Próximo cobro en $days días';
      accent = MangoColors.primaryOrange;
    } else {
      headline = 'Próximo cobro en $days días';
      accent = MangoColors.successGreen;
    }

    return _Card(
      accentColor: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_repeat_rounded, color: accent, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headline,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
                ),
              ),
            ],
          ),
          if (next != null) ...[
            const SizedBox(height: 6),
            Text(
              formatter.format(next),
              style: const TextStyle(fontSize: 13, color: MangoColors.muted),
            ),
          ],
          if (state.plan != null) ...[
            const SizedBox(height: 4),
            Text(
              'Monto: ${state.plan!.formattedPrice}',
              style: const TextStyle(
                fontSize: 13,
                color: MangoColors.darkGray,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (state.billingStatus == BillingStatus.pastDue &&
              state.currentAttemptNumber > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Intento ${state.currentAttemptNumber} de 3. Reintentaremos automáticamente.',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFFB45309),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PaymentMethodSummary extends StatelessWidget {
  final dynamic paymentMethod;
  const _PaymentMethodSummary({required this.paymentMethod});

  @override
  Widget build(BuildContext context) {
    return _Card(
      onTap: () => context.go(AppRoutes.settingsBillingPaymentMethod),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFFFFE6D5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.credit_card_rounded,
              color: MangoColors.primaryOrange,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Método de pago',
                  style: TextStyle(fontSize: 13, color: MangoColors.muted),
                ),
                const SizedBox(height: 2),
                if (paymentMethod == null)
                  const Text(
                    'No has registrado una tarjeta',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: MangoColors.darkGray,
                    ),
                  )
                else
                  Text(
                    '${paymentMethod.brand} •••• ${paymentMethod.last4} · ${paymentMethod.formattedExpiration}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: MangoColors.darkGray,
                    ),
                  ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: MangoColors.muted),
        ],
      ),
    );
  }
}

class _LastChargeCard extends StatelessWidget {
  final BillingState state;
  const _LastChargeCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final last = state.lastSuccessfulCharge ?? state.lastFailedCharge;
    if (last == null) return const SizedBox.shrink();
    final formatter = DateFormat("d MMM yyyy", 'es');

    return _Card(
      onTap: () => context.go(AppRoutes.settingsBillingHistory),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFFE8F8EF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.history_rounded,
              color: MangoColors.successGreen,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Último cobro',
                  style: TextStyle(fontSize: 13, color: MangoColors.muted),
                ),
                const SizedBox(height: 2),
                Text(
                  '${formatter.format(last.attemptedAt)} · ${last.formattedAmount} · ${last.status.label}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: MangoColors.darkGray,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: MangoColors.muted),
        ],
      ),
    );
  }
}

class _ActionsList extends StatelessWidget {
  final BillingState state;
  const _ActionsList({required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ActionTile(
          icon: Icons.workspace_premium_rounded,
          label: 'Cambiar de plan',
          subtitle: 'Mira lo que incluye cada plan y cambia cuando quieras',
          onTap: () => context.go(AppRoutes.settingsBillingPlans),
        ),
        _ActionTile(
          icon: Icons.credit_card_rounded,
          label: 'Gestionar tarjeta',
          subtitle: 'Cambiar o eliminar el método de pago actual',
          onTap: () => context.go(AppRoutes.settingsBillingPaymentMethod),
        ),
        _ActionTile(
          icon: Icons.receipt_long_rounded,
          label: 'Historial de cobros',
          subtitle: 'Ver y descargar comprobantes',
          onTap: () => context.go(AppRoutes.settingsBillingHistory),
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _Card(
        onTap: onTap,
        child: Row(
          children: [
            Icon(icon, color: MangoColors.primaryOrange, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: MangoColors.muted,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: MangoColors.muted),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final BillingStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (status.severity) {
      'success' => (const Color(0xFFE8F8EF), const Color(0xFF15803D)),
      'warning' => (const Color(0xFFFEF3C7), const Color(0xFFB45309)),
      'danger' => (const Color(0xFFFEE2E2), const Color(0xFFB91C1C)),
      _ => (const Color(0xFFE6F0FE), const Color(0xFF1D4ED8)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status.label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: fg),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers visuales
// ---------------------------------------------------------------------------

class _Card extends StatelessWidget {
  final Widget child;
  final Color? accentColor;
  final VoidCallback? onTap;
  const _Card({required this.child, this.accentColor, this.onTap});

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 14,
            offset: Offset(0, 2),
          ),
        ],
        // Hairline accent en el borde izquierdo cuando hay color de énfasis.
      ),
      child: accentColor != null
          // IntrinsicHeight acota la altura del Row para que la barra de acento
          // (CrossAxisAlignment.stretch) iguale el alto del contenido en vez de
          // pedir altura infinita (que crashea en contexto no acotado).
          ? IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 3,
                    margin: const EdgeInsets.only(right: 12),
                    decoration: BoxDecoration(
                      color: accentColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(child: child),
                ],
              ),
            )
          : child,
    );
    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: card,
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  final String message;
  const _ErrorPanel({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFB91C1C), size: 40),
            const SizedBox(height: 12),
            const Text(
              'No pudimos cargar tu suscripción',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: const TextStyle(fontSize: 13, color: MangoColors.muted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _NotSetUpPanel extends StatelessWidget {
  const _NotSetUpPanel();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.workspace_premium_outlined,
              color: MangoColors.primaryOrange,
              size: 48,
            ),
            const SizedBox(height: 12),
            const Text(
              'Aún no tienes una suscripción activa',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            const Text(
              'Elige un plan para empezar a usar MangoPOS sin límites.',
              style: TextStyle(fontSize: 13, color: MangoColors.muted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
                foregroundColor: MangoColors.white,
              ),
              onPressed: () => context.go(AppRoutes.settingsBillingPlans),
              child: const Text('Ver planes disponibles'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoBusinessScaffold extends StatelessWidget {
  const _NoBusinessScaffold();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        title: const Text('Suscripción y pagos'),
      ),
      body: const Center(
        child: Text('Selecciona un negocio para ver su suscripción'),
      ),
    );
  }
}
