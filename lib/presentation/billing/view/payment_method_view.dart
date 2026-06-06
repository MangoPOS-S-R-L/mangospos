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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_colors.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/billing_payment_method.dart';
import '../../../data/repositories/billing_repository.dart';
import '../../../services/session/session_controller.dart';
import '../providers/billing_providers.dart';

class PaymentMethodView extends ConsumerStatefulWidget {
  const PaymentMethodView({super.key});

  @override
  ConsumerState<PaymentMethodView> createState() => _PaymentMethodViewState();
}

class _PaymentMethodViewState extends ConsumerState<PaymentMethodView> {
  bool _starting = false;
  bool _waitingForCallback = false;
  String? _lastError;
  DateTime? _sessionExpiresAt;
  BillingPaymentMethod? _baselineMethod;
  Timer? _timeoutTimer;

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _onChangeCard() async {
    final session = ref.read(sessionProvider);
    final businessId = session.activeBusinessId;
    if (businessId == null) return;

    final repo = ref.read(billingRepositoryProvider);

    setState(() {
      _starting = true;
      _lastError = null;
    });

    try {
      // Snapshot del método actual para detectar cambios via stream.
      _baselineMethod = ref.read(defaultPaymentMethodProvider(businessId)).valueOrNull;

      final result = await repo.createTokenizationSession(
        businessId: businessId,
        intentType: _baselineMethod == null ? 'tokenize_and_verify' : 'replace_card',
      );

      final uri = Uri.parse(result.paymentPageUrl);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw BillingRepositoryException(
          'No se pudo abrir la pasarela de pagos. Verifica que tu dispositivo '
          'tenga un navegador instalado.',
        );
      }
      if (!mounted) return;
      setState(() {
        _starting = false;
        _waitingForCallback = true;
        _sessionExpiresAt = result.expiresAt;
      });
      _startTimeoutTimer();
    } on BillingRepositoryException catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _lastError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _lastError = e.toString();
      });
    }
  }

  void _startTimeoutTimer() {
    _timeoutTimer?.cancel();
    final expiresAt = _sessionExpiresAt;
    if (expiresAt == null) return;
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative) return;
    _timeoutTimer = Timer(remaining, () {
      if (!mounted) return;
      setState(() {
        _waitingForCallback = false;
        _lastError = 'La sesión expiró. Intenta nuevamente.';
      });
    });
  }

  void _onCardArrived() {
    _timeoutTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _waitingForCallback = false;
      _lastError = null;
    });
    AppToast.success(context, 'Tarjeta verificada y guardada correctamente.');
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

    // Detecta arribo de nueva tarjeta mientras estamos esperando callback.
    ref.listen(defaultPaymentMethodProvider(businessId), (prev, next) {
      if (!_waitingForCallback) return;
      final newMethod = next.valueOrNull;
      if (newMethod == null) return;
      if (_baselineMethod?.id != newMethod.id &&
          newMethod.status == BillingPaymentMethodStatus.verified) {
        _onCardArrived();
      }
    });

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
            if (_waitingForCallback)
              _WaitingPanel(expiresAt: _sessionExpiresAt)
            else if (_lastError != null)
              _ErrorBanner(message: _lastError!),
            const SizedBox(height: 12),
            _ChangeCardButton(
              isLoading: _starting,
              isWaiting: _waitingForCallback,
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

class _WaitingPanel extends StatelessWidget {
  final DateTime? expiresAt;
  const _WaitingPanel({required this.expiresAt});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFE6F0FE),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF93C5FD)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF1D4ED8)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Esperando confirmación de Azul…',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1D4ED8),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Completa el pago en el navegador y regresa aquí. '
                  '${expiresAt != null ? "Tienes hasta ${DateFormat('HH:mm', 'es').format(expiresAt!)} para terminar." : ""}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF1E3A8A), height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
