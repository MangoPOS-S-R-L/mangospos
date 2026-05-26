// Bloqueo visible cuando billing_status='suspended' (PRD §8.3).
//
// La idea: al usuario suspendido SOLO se le ofrece una acción — actualizar
// tarjeta. El resto de la app queda inaccesible hasta que el cobro pase.
// Este overlay se monta DENTRO de MySubscriptionView; un guard global a nivel
// router (settings_view o shell) puede redirigir aquí para impedir uso del POS.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_colors.dart';
import '../../../data/models/billing_state.dart';

class SuspendedOverlay extends StatelessWidget {
  final BillingState state;
  const SuspendedOverlay({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final formatter = DateFormat("d 'de' MMMM yyyy", 'es');
    final suspendedAt = state.suspendedAt;
    final lastFail = state.lastFailedCharge;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: MangoColors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFFCA5A5), width: 1.5),
              boxShadow: const [
                BoxShadow(color: Color(0x14000000), blurRadius: 18, offset: Offset(0, 4)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEE2E2),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: const Icon(Icons.block_rounded,
                      color: Color(0xFFB91C1C), size: 30),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Tu suscripción está suspendida',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFB91C1C),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Intentamos cobrar tu plan 3 veces y todas fueron rechazadas. '
                  'Actualiza tu método de pago para reactivar el servicio.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: MangoColors.darkGray.withValues(alpha: 0.85),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 18),
                if (suspendedAt != null)
                  _DetailRow(
                    label: 'Suspendida el',
                    value: formatter.format(suspendedAt),
                  ),
                if (lastFail != null) ...[
                  _DetailRow(
                    label: 'Último intento',
                    value: '${formatter.format(lastFail.attemptedAt)} · '
                        '${lastFail.formattedAmount}',
                  ),
                  if (lastFail.responseMessage != null &&
                      lastFail.responseMessage!.isNotEmpty)
                    _DetailRow(
                      label: 'Motivo',
                      value: lastFail.responseMessage!,
                    ),
                ],
                if (state.plan != null)
                  _DetailRow(label: 'Plan', value: state.plan!.name),
                const SizedBox(height: 22),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: MangoColors.primaryOrange,
                    foregroundColor: MangoColors.white,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => context.go(AppRoutes.settingsBillingPaymentMethod),
                  child: const Text(
                    'Actualizar método de pago',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Cuando tu nueva tarjeta sea verificada, intentaremos el cobro '
                  'inmediatamente y reactivaremos el servicio.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: MangoColors.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                color: MangoColors.darkGray,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
