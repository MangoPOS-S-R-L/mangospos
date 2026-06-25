// Botón "Pagar ahora" — cobro manual de la suscripción de MangoPOS con la
// tarjeta default. Reutilizable: se usa en "Suscripción y pagos" y en "Método
// de pago".
//
// REGLA: solo se HABILITA dentro de las 48 h previas a la fecha de cobro (o si
// ya está vencida) — ver [BillingState.isWithinPayWindow]. Fuera de esa ventana
// muestra una nota con la fecha en que se habilita. El cobro automático (cron)
// NO pasa por aquí, así que ese gate no le aplica.
//
// El cobro real reusa el camino de producción: azul-charge-now (autoriza al
// dueño) → azul-charge-subscription (mTLS + token DataVault), idempotente.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/mango_colors.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/billing_state.dart';
import '../../../data/repositories/billing_repository.dart';
import '../providers/billing_providers.dart';

class PayNowButton extends ConsumerStatefulWidget {
  final String businessId;
  final BillingState state;
  const PayNowButton({
    super.key,
    required this.businessId,
    required this.state,
  });

  @override
  ConsumerState<PayNowButton> createState() => _PayNowButtonState();
}

class _PayNowButtonState extends ConsumerState<PayNowButton> {
  bool _loading = false;

  Future<void> _pay() async {
    final amount = widget.state.plan?.formattedPrice;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pagar suscripción'),
        content: Text(
          amount == null
              ? '¿Cobrar tu suscripción ahora con la tarjeta registrada?'
              : 'Se cobrará $amount a tu tarjeta registrada. ¿Continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: MangoColors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Pagar ahora'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _loading = true);
    try {
      final result = await ref
          .read(billingRepositoryProvider)
          .chargeNow(businessId: widget.businessId);
      if (!mounted) return;
      // Refrescar estado + histórico tras el cobro.
      ref.invalidate(billingStateProvider(widget.businessId));
      ref.invalidate(chargesProvider(widget.businessId));
      if (result.approved) {
        AppToast.success(
          context,
          result.idempotent
              ? 'Tu suscripción ya estaba al día.'
              : '¡Pago aprobado! Gracias.',
        );
      } else {
        final msg = result.responseMessage;
        AppToast.error(
          context,
          'Tarjeta declinada${msg != null && msg.isNotEmpty ? ': $msg' : ''}.',
        );
      }
    } on BillingRepositoryException catch (e) {
      if (mounted) AppToast.error(context, e.message);
    } catch (_) {
      if (mounted) AppToast.error(context, 'No se pudo procesar el cobro.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;

    // Gate de 48 h: fuera de la ventana mostramos una nota en vez del botón.
    if (!state.isWithinPayWindow) {
      final next = state.nextBillingDate;
      final fmt = DateFormat("d 'de' MMMM", 'es');
      final whenText = next != null
          ? 'El pago se habilita 48 horas antes de tu fecha de cobro '
                '(${fmt.format(next)}).'
          : 'El pago manual se habilitará cerca de tu fecha de cobro.';
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F3F6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: MangoColors.cardBorder),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.lock_clock_rounded,
              size: 20,
              color: MangoColors.muted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                whenText,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: MangoColors.muted,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final amount = state.plan?.formattedPrice;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: MangoColors.primaryOrange,
          foregroundColor: MangoColors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: _loading ? null : _pay,
        icon: _loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: MangoColors.white,
                ),
              )
            : const Icon(Icons.bolt_rounded),
        label: Text(
          _loading
              ? 'Procesando…'
              : (amount != null ? 'Pagar ahora · $amount' : 'Pagar ahora'),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}
