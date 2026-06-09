// Pantalla de método de pago.
//
// Flujo de "Cambiar tarjeta" (PRD §8.4):
//   1. Click → invoca azul-create-tokenization-session (Edge Fn).
//   2. Recibe payment_page_url y abre en browser externo (url_launcher).
//   3. Mientras tanto, mostramos pantalla "Esperando confirmación..." con
//      indicación de qué pasar en Azul.
//   4. El stream Realtime de azul_payment_methods detecta cuando el callback
//      del backend inserta la nueva tarjeta y la UI se actualiza sola.
//   5. El usuario regresa a la app y ve la nueva tarjeta como default.
//
// Cross-platform: url_launcher abre el browser nativo de cada plataforma
// (Safari/Chrome/Edge según OS). No usamos WebView interno porque la cobertura
// cross-platform es heterogénea (no funciona limpio en desktop sin más deps).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_colors.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/billing_payment_method.dart';
import '../../../services/session/session_controller.dart';
import '../providers/billing_providers.dart';
import '../widgets/azul_card_form_sheet.dart';

class PaymentMethodView extends ConsumerStatefulWidget {
  const PaymentMethodView({super.key});

  @override
  ConsumerState<PaymentMethodView> createState() => _PaymentMethodViewState();
}

class _PaymentMethodViewState extends ConsumerState<PaymentMethodView> {
  String? _lastError;

  Future<void> _onChangeCard() async {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null) return;
    setState(() => _lastError = null);
    final result =
        await AzulCardFormSheet.show(context, businessId: businessId);
    if (!mounted || result == null) return;
    AppToast.success(context, 'Tarjeta guardada correctamente.');
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final businessId = session.activeBusinessId;
    if (businessId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Método de pago')),
        body: const Center(child: Text('Selecciona un negocio')),
      );
    }

    final pmAsync = ref.watch(defaultPaymentMethodProvider(businessId));

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
            const SizedBox(height: 16),
            if (_lastError != null) _ErrorBanner(message: _lastError!),
            const SizedBox(height: 12),
            _ChangeCardButton(
              isLoading: false,
              isWaiting: false,
              hasCard: pm != null,
              onTap: _onChangeCard,
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
          BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 6)),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 10, fontWeight: FontWeight.w700),
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
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            child: const Icon(Icons.credit_card_off_rounded,
                color: MangoColors.primaryOrange, size: 28),
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
                  style: TextStyle(fontSize: 12, color: MangoColors.muted, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Panel "esperando confirmación de Azul"
// ---------------------------------------------------------------------------

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFB91C1C), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 13, color: Color(0xFFB91C1C), height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CTA
// ---------------------------------------------------------------------------

class _ChangeCardButton extends StatelessWidget {
  final bool isLoading;
  final bool isWaiting;
  final bool hasCard;
  final VoidCallback onTap;

  const _ChangeCardButton({
    required this.isLoading,
    required this.isWaiting,
    required this.hasCard,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = isLoading || isWaiting;
    final label = isLoading
        ? 'Preparando pasarela…'
        : isWaiting
            ? 'Esperando confirmación…'
            : (hasCard ? 'Cambiar tarjeta' : 'Agregar tarjeta');

    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: disabled ? null : onTap,
        style: FilledButton.styleFrom(
          backgroundColor: MangoColors.primaryOrange,
          foregroundColor: MangoColors.white,
          disabledBackgroundColor: MangoColors.cardBorder,
          disabledForegroundColor: MangoColors.muted,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        icon: isLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.lock_rounded, size: 18),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
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
          const Icon(Icons.verified_user_outlined, color: MangoColors.muted, size: 20),
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
                  'Tus datos de tarjeta se manejan exclusivamente en los servidores '
                  'de Azul (procesador local certificado). MangoPOS solo guarda el '
                  'token y los últimos 4 dígitos.',
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
