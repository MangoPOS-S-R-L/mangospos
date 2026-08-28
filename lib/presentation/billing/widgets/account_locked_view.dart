// Pantalla completa de bloqueo por falta de pago.
//
// Es la ÚNICA cosa que ve el dueño cuando su cuenta queda bloqueada. Por eso
// tiene tres cosas y nada más:
//   1. Qué pasó, en su idioma y sin jerga interna.
//   2. Cómo salir: pagar ahora / actualizar tarjeta.
//   3. A quién llamar, con el teléfono marcable.
//
// No hay botón de "continuar de todos modos" — si lo hubiera, el bloqueo no
// sería un bloqueo. La salida es pagar o hablar con soporte.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_colors.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/account_access_state.dart';
import '../providers/access_providers.dart';

class AccountLockedView extends ConsumerWidget {
  const AccountLockedView({super.key, required this.state});

  final AccountAccessState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final df = DateFormat("d 'de' MMMM yyyy", 'es');
    final canSelfServe = state.reason != AccessReason.manualLock &&
        state.reason != AccessReason.accountInactive &&
        state.reason != AccessReason.verificationStale;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: AppColors.destructive.withValues(alpha: 0.30),
                    width: 1.5,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 22,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 60,
                        height: 60,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.destructive.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Icon(
                          state.reason == AccessReason.verificationStale
                              ? Icons.wifi_off_rounded
                              : Icons.lock_rounded,
                          color: AppColors.destructive,
                          size: 30,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      state.title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        color: AppColors.destructive,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      state.body,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14.5,
                        height: 1.55,
                        color: AppColors.foreground.withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ---- Detalle ------------------------------------------
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          if (state.planName != null)
                            _Row(label: 'Plan', value: state.planName!),
                          if (state.amountCents != null &&
                              state.amountCents! > 0)
                            _Row(
                              label: 'Mensualidad',
                              value: _money(
                                state.amountCents!,
                                state.currencyCode,
                              ),
                            ),
                          if (state.lockedAt != null)
                            _Row(
                              label: 'Bloqueado desde',
                              value: df.format(state.lockedAt!),
                            ),
                          if (state.nextBillingDate != null)
                            _Row(
                              label: 'Fecha de cobro',
                              value: df.format(state.nextBillingDate!),
                            ),
                          if (state.fromCache)
                            _Row(
                              label: 'Última verificación',
                              value: df.format(state.cachedAt),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),

                    // ---- Salidas ------------------------------------------
                    if (canSelfServe) ...[
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: MangoColors.primaryOrange,
                          foregroundColor: MangoColors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () =>
                            context.go(AppRoutes.settingsBillingPaymentMethod),
                        child: const Text(
                          'Actualizar método de pago',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => context.go(AppRoutes.settingsBilling),
                        child: const Text('Ver mi suscripción'),
                      ),
                      const SizedBox(height: 10),
                    ],

                    if (state.contactPhone != null &&
                        state.contactPhone!.trim().isNotEmpty)
                      _ContactCard(state: state),

                    const SizedBox(height: 14),
                    TextButton.icon(
                      onPressed: () => ref
                          .read(refreshAccountAccessProvider)(state.businessId),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Ya pagué — verificar de nuevo'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.mutedForeground,
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

  static String _money(int cents, String? currency) {
    final symbol = (currency ?? 'DOP') == 'DOP' ? 'RD\$' : '${currency ?? ''} ';
    final f = NumberFormat('#,##0.00', 'es');
    return '$symbol${f.format(cents / 100)}';
  }
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({required this.state});

  final AccountAccessState state;

  @override
  Widget build(BuildContext context) {
    final phone = state.contactPhone!.trim();
    final name = state.contactName?.trim();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.infoSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.support_agent_rounded,
              color: AppColors.info, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name != null && name.isNotEmpty
                      ? 'Comunícate con $name'
                      : 'Comunícate con soporte',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  phone,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _call(phone),
            child: const Text('Llamar'),
          ),
        ],
      ),
    );
  }

  Future<void> _call(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^\d+]'), ''));
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.mutedForeground,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
