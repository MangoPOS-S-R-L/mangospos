// Bloqueo visible cuando billing_status='trial' Y no hay payment_method
// verificado (PRD-Azul-Subscriptions §8.1 — tarjeta obligatoria al onboarding).
//
// Cubre 2 escenarios:
//   1. Edge case del registro: el comercio cerró el browser entre Step 3 y
//      Step 4, dejando la cuenta creada sin tokenización.
//   2. Comercios pilotos pre-existentes que aún no tienen tarjeta cargada.
//
// El overlay sustituye TODA la pantalla del shell autenticado. La única acción
// disponible es ir a Settings → Suscripción → Método de pago para registrar
// tarjeta. El BillingGuard libera el overlay automáticamente vía Realtime
// cuando llega payment_method.status='verified'.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_colors.dart';
import '../../../data/models/billing_state.dart';

class PaymentMethodRequiredOverlay extends StatelessWidget {
  final BillingState? state;
  const PaymentMethodRequiredOverlay({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final formatter = DateFormat("d 'de' MMMM yyyy", 'es');
    final trialEnds = state?.trialEndsAt;
    final daysLeft = state?.trialDaysRemaining;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: MangoColors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFFFDDC2), width: 1.5),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 24,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF7F1),
                        borderRadius: BorderRadius.circular(36),
                      ),
                      child: const Icon(
                        Icons.credit_card_rounded,
                        color: MangoColors.primaryOrange,
                        size: 36,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Registra tu método de pago',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Para empezar a usar MangoPOS necesitas tener una tarjeta '
                      'registrada. No haremos ningún cargo durante el trial — '
                      'validamos la tarjeta con RD\$1.00 que se reembolsa al instante.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.55,
                        color: MangoColors.darkGray.withValues(alpha: 0.8),
                      ),
                    ),
                    if (trialEnds != null) ...[
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF7F1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.timer_outlined,
                                color: MangoColors.primaryOrange, size: 18),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                daysLeft != null && daysLeft > 0
                                    ? 'Tu prueba gratis termina el '
                                        '${formatter.format(trialEnds)} '
                                        '(${daysLeft == 1 ? "queda 1 día" : "quedan $daysLeft días"})'
                                    : 'Tu prueba gratis terminó el ${formatter.format(trialEnds)}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: MangoColors.primaryOrange,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: MangoColors.primaryOrange,
                        foregroundColor: MangoColors.white,
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () =>
                          context.go(AppRoutes.settingsBillingPaymentMethod),
                      icon: const Icon(Icons.lock_rounded, size: 18),
                      label: const Text(
                        'Registrar tarjeta ahora',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Procesado por Azul · Tus datos nunca pasan por MangoPOS.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: MangoColors.muted.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
