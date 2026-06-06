// Step 4 del registro: registro del método de pago (PRD-Azul-Subscriptions §8.1).
//
// Se llega acá DESPUÉS de que Step 3 termina exitosamente la creación del
// business + membership anchor. La sesión Supabase ya está activa (JWT), así
// que podemos invocar `azul-create-tokenization-session` con autenticación.
//
// Flujo:
//   1. Click "Registrar tarjeta" → invoca Edge Function → recibe payment_page_url
//   2. Abrimos URL en browser externo (url_launcher) — Azul muestra su form
//   3. Mostramos "Esperando confirmación..." con listener Realtime al stream
//      de `azul_payment_methods` del business actual
//   4. Cuando llega payment_method.status='verified' → SUCCESS → ir a dashboard
//   5. Si el usuario cierra el browser sin completar, expira a los 30 min
//
// Tarjeta requerida:
//   - No hay opción de saltar. Sin tarjeta tokenizada, la cuenta queda en
//     estado pending y un cron de cleanup la elimina pasadas 24h. El comercio
//     puede cerrar el browser y volver, pero el dashboard no se desbloquea
//     hasta que tenga payment_method verified.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mangopos/core/utils/app_toast.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_tokens.dart';
import '../../../data/models/billing_payment_method.dart';
import '../../../data/repositories/billing_repository.dart';
import '../../../services/session/session_controller.dart';
import '../../billing/providers/billing_providers.dart';
import '../widgets/auth_shell.dart';

class RegisterStep4View extends ConsumerStatefulWidget {
  const RegisterStep4View({super.key});

  @override
  ConsumerState<RegisterStep4View> createState() => _RegisterStep4ViewState();
}

class _RegisterStep4ViewState extends ConsumerState<RegisterStep4View> {
  bool _starting = false;
  bool _waitingForCallback = false;
  String? _error;
  DateTime? _sessionExpiresAt;
  BillingPaymentMethod? _baselineMethod;
  Timer? _timeoutTimer;

  static const _steps = <AuthShellStep>[
    AuthShellStep(title: 'Crear cuenta', complete: true),
    AuthShellStep(title: 'Agregar negocio', complete: true),
    AuthShellStep(title: 'Activación', complete: true),
    AuthShellStep(title: 'Método de pago'),
  ];

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _onRegisterCard() async {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null) {
      setState(() => _error = 'Sesión no disponible. Reinicia el registro.');
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final repo = ref.read(billingRepositoryProvider);
      _baselineMethod =
          ref.read(defaultPaymentMethodProvider(businessId)).valueOrNull;

      final result = await repo.createTokenizationSession(
        businessId: businessId,
      );
      final launched = await launchUrl(
        Uri.parse(result.paymentPageUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw BillingRepositoryException(
          'No se pudo abrir la pasarela. Verifica que tengas un navegador.',
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
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = e.toString();
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
        _error = 'La sesión expiró. Intenta nuevamente.';
      });
    });
  }

  void _onCardArrived() {
    _timeoutTimer?.cancel();
    if (!mounted) return;
    AppToast.success(context, '¡Tarjeta verificada! Bienvenido a MangoPOS.');
    context.go(AppRoutes.dashboard);
  }

  @override
  Widget build(BuildContext context) {
    final businessId = ref.watch(sessionProvider).activeBusinessId;

    // Listener Realtime: cuando llega la tarjeta verificada, redirigir.
    if (businessId != null && _waitingForCallback) {
      ref.listen(defaultPaymentMethodProvider(businessId), (prev, next) {
        final pm = next.valueOrNull;
        if (pm == null) return;
        if (_baselineMethod?.id != pm.id &&
            pm.status == BillingPaymentMethodStatus.verified) {
          _onCardArrived();
        }
      });
    }

    return AuthShell(
      brandSubtitle: 'Método de pago',
      steps: _steps,
      currentStep: 3,
      main: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7F1),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(
                  Icons.credit_card_rounded,
                  size: 42,
                  color: MangoTokens.primary,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Registra tu método de pago',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: MangoTokens.foreground,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'No haremos ningún cargo durante el período de prueba. '
                'Validamos tu tarjeta con un cobro temporal de RD\$1.00 '
                'que será reembolsado automáticamente.',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 15,
                  height: 1.55,
                  color: MangoTokens.mutedForeground,
                ),
              ),
              const SizedBox(height: 28),
              if (_waitingForCallback) _waitingPanel() else _bullets(),
              if (_error != null) ...[
                const SizedBox(height: 16),
                _errorBanner(_error!),
              ],
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: MangoTokens.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: _starting || _waitingForCallback
                      ? null
                      : _onRegisterCard,
                  icon: _starting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.lock_rounded, size: 20),
                  label: Text(
                    _starting
                        ? 'Abriendo Azul…'
                        : _waitingForCallback
                            ? 'Esperando confirmación…'
                            : 'Registrar tarjeta ahora',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Sin tarjeta verificada no podrás acceder al panel. '
                'Tu prueba gratis empieza apenas registres el método de pago.',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  color: MangoTokens.mutedForeground,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
      side: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _securityCard(),
            const SizedBox(height: 14),
            _trialReminderCard(),
          ],
        ),
      ),
    );
  }

  Widget _bullets() {
    final items = [
      ('Verificación de RD\$1.00', 'Se reembolsa al instante.'),
      ('Sin cargos durante 14 días', 'Cobramos al terminar la prueba.'),
      ('Cancela cuando quieras', 'Desde Configuración → Suscripción.'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items.map((it) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.check_circle_rounded,
                  color: MangoTokens.success, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      it.$1,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: MangoTokens.foreground,
                      ),
                    ),
                    Text(
                      it.$2,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        color: MangoTokens.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _waitingPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFE6F0FE),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF93C5FD)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Color(0xFF1D4ED8),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Esperando confirmación de Azul…',
                  style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF1D4ED8),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Completa el pago en el navegador y regresa aquí. '
                  'Esta página se actualizará automáticamente.',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    color: const Color(0xFF1E3A8A),
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

  Widget _errorBanner(String msg) {
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
          const Icon(Icons.error_outline, color: Color(0xFFB91C1C), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                color: const Color(0xFFB91C1C),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _securityCard() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: MangoTokens.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.verified_user_outlined,
                    color: MangoTokens.primary, size: 22),
                const SizedBox(width: 10),
                Text(
                  'Procesado por Azul',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: MangoTokens.foreground,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Los datos de tu tarjeta nunca pasan por MangoPOS. Se manejan '
              'directamente con Azul, el procesador local certificado de '
              'República Dominicana. Solo guardamos un token cifrado y los '
              'últimos 4 dígitos para identificarla.',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                color: MangoTokens.mutedForeground,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trialReminderCard() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7F1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFFDDC2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.timer_outlined,
                    color: MangoTokens.primary, size: 22),
                const SizedBox(width: 10),
                Text(
                  'Tu prueba ya empezó',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: MangoTokens.foreground,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Tienes 14 días para probar MangoPOS sin compromiso. '
              'Al terminar, cobraremos el plan que elegiste. Puedes cambiarlo '
              'o cancelarlo en cualquier momento desde Configuración.',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                color: MangoTokens.mutedForeground,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
