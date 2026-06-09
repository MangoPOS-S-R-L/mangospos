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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:mangopos/core/utils/app_toast.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_tokens.dart';
import '../../../services/session/session_controller.dart';
import '../../billing/widgets/azul_card_form_sheet.dart';
import '../widgets/auth_shell.dart';

class RegisterStep4View extends ConsumerStatefulWidget {
  const RegisterStep4View({super.key});

  @override
  ConsumerState<RegisterStep4View> createState() => _RegisterStep4ViewState();
}

class _RegisterStep4ViewState extends ConsumerState<RegisterStep4View> {
  String? _error;

  static const _steps = <AuthShellStep>[
    AuthShellStep(title: 'Crear cuenta', complete: true),
    AuthShellStep(title: 'Agregar negocio', complete: true),
    AuthShellStep(title: 'Activación', complete: true),
    AuthShellStep(title: 'Método de pago'),
  ];

  Future<void> _onRegisterCard() async {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null) {
      setState(() => _error = 'Sesión no disponible. Reinicia el registro.');
      return;
    }
    setState(() => _error = null);
    final result =
        await AzulCardFormSheet.show(context, businessId: businessId);
    if (!mounted || result == null) return;
    AppToast.success(context, '¡Tarjeta registrada! Bienvenido a MangoPOS.');
    context.go(AppRoutes.dashboard);
  }

  @override
  Widget build(BuildContext context) {
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
                'Guardamos tu tarjeta de forma segura para cobrar el plan '
                'cuando termine la prueba.',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 15,
                  height: 1.55,
                  color: MangoTokens.mutedForeground,
                ),
              ),
              const SizedBox(height: 28),
              _bullets(),
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
                  onPressed: _onRegisterCard,
                  icon: const Icon(Icons.lock_rounded, size: 20),
                  label: Text(
                    'Registrar tarjeta ahora',
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
      ('Tarjeta guardada con seguridad', 'Tokenizada por Azul; no guardamos el número.'),
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
              'Tus datos viajan cifrados a Azul, el procesador local '
              'certificado de República Dominicana, para tokenizar tu tarjeta. '
              'Guardamos solo un token cifrado y los últimos 4 dígitos — '
              'nunca el número completo ni el código de seguridad.',
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
