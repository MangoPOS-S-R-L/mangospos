// Pantalla "Tu cuenta está en revisión". Se muestra como overlay
// bloqueante cuando businesses.status='pending'. El equipo interno
// activa la cuenta vía Mango Administrador.
//
// Ofrece 3 acciones:
//   1. Solicitar activación → mailto a soporte con asunto/cuerpo
//      pre-llenados (email del usuario + business_id). Soporte activa
//      la cuenta desde el panel administrativo.
//   2. Cambiar contraseña → dispara Supabase resetPasswordForEmail al
//      email autenticado. El usuario recibe un link de reseteo.
//   3. Cerrar sesión → libera la sesión y vuelve a /login.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/router/routes.dart';
import '../../app/theme/mango_colors.dart';
import '../../core/utils/app_toast.dart';
import '../../services/session/session_controller.dart';

const String _kSupportEmail = 'soporte@mangopos.do';

class PendingApprovalScreen extends ConsumerStatefulWidget {
  final String businessId;
  const PendingApprovalScreen({super.key, required this.businessId});

  @override
  ConsumerState<PendingApprovalScreen> createState() =>
      _PendingApprovalScreenState();
}

class _PendingApprovalScreenState
    extends ConsumerState<PendingApprovalScreen> {
  bool _sendingReset = false;
  bool _loggingOut = false;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final userEmail =
        Supabase.instance.client.auth.currentUser?.email ?? '';
    final businessName =
        session.activeBusinessName?.trim().isNotEmpty == true
            ? session.activeBusinessName!.trim()
            : 'tu negocio';

    return Scaffold(
      backgroundColor: const Color(0xFFFBFAF9),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: MangoColors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF0E7),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Icon(
                          Icons.hourglass_top_rounded,
                          color: MangoColors.primaryOrange,
                          size: 32,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Tu cuenta está en revisión',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Estamos validando los datos de $businessName antes '
                      'de habilitar el acceso al POS. Esto suele tomar '
                      'unas horas en horario laboral. Te avisaremos por '
                      'correo cuando esté lista.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: MangoColors.darkGray.withValues(alpha: 0.85),
                        height: 1.55,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _InfoBox(
                      email: userEmail.isEmpty ? '—' : userEmail,
                      businessId: widget.businessId,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () => _sendActivationEmail(
                        context,
                        userEmail: userEmail,
                        businessName: businessName,
                        businessId: widget.businessId,
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: MangoColors.primaryOrange,
                        foregroundColor: MangoColors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.mark_email_read_outlined, size: 18),
                      label: const Text(
                        'Solicitar activación por correo',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _sendingReset || userEmail.isEmpty
                          ? null
                          : () => _sendPasswordReset(context, userEmail),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF111827),
                        minimumSize: const Size.fromHeight(48),
                        side: const BorderSide(color: Color(0xFFE5E7EB)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: _sendingReset
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.lock_reset_rounded, size: 18),
                      label: const Text(
                        'Cambiar mi contraseña',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 18),
                    TextButton.icon(
                      onPressed: _loggingOut
                          ? null
                          : () => _logout(context),
                      icon: const Icon(Icons.logout_rounded,
                          size: 16, color: Color(0xFF6B7280)),
                      label: Text(
                        _loggingOut ? 'Cerrando sesión…' : 'Cerrar sesión',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
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

  Future<void> _sendActivationEmail(
    BuildContext context, {
    required String userEmail,
    required String businessName,
    required String businessId,
  }) async {
    final subject = Uri.encodeComponent(
      'Solicitud de activación — $businessName',
    );
    final body = Uri.encodeComponent(
      'Hola equipo de MangoPOS,\n\n'
      'Acabo de registrar mi cuenta y necesito que la activen para '
      'empezar a operar.\n\n'
      'Datos de la cuenta:\n'
      '• Negocio: $businessName\n'
      '• Email: ${userEmail.isEmpty ? '(sin email)' : userEmail}\n'
      '• Business ID: $businessId\n\n'
      'Gracias.',
    );
    final uri = Uri.parse(
      'mailto:$_kSupportEmail?subject=$subject&body=$body',
    );
    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!context.mounted) return;
    if (!launched) {
      _showSnack(
        context,
        'No pudimos abrir tu cliente de correo. Escríbenos a '
        '$_kSupportEmail.',
        isError: true,
      );
    }
  }

  Future<void> _sendPasswordReset(
    BuildContext context,
    String email,
  ) async {
    setState(() => _sendingReset = true);
    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(email);
      if (!context.mounted) return;
      _showSnack(
        context,
        'Te enviamos un correo a $email con instrucciones para cambiar '
        'tu contraseña.',
      );
    } catch (e) {
      if (!context.mounted) return;
      _showSnack(
        context,
        'No pudimos enviar el correo de reseteo. Intenta de nuevo en '
        'un momento.',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _sendingReset = false);
    }
  }

  Future<void> _logout(BuildContext context) async {
    setState(() => _loggingOut = true);
    try {
      await ref.read(sessionProvider.notifier).signOut();
      if (!context.mounted) return;
      context.go(AppRoutes.login);
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  void _showSnack(BuildContext context, String message,
      {bool isError = false}) {
    if (isError) {
      AppToast.error(context, message);
    } else {
      AppToast.success(context, message);
    }
  }
}

class _InfoBox extends StatelessWidget {
  final String email;
  final String businessId;
  const _InfoBox({required this.email, required this.businessId});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(Icons.alternate_email_rounded, 'Correo', email),
          const SizedBox(height: 8),
          _row(Icons.tag_rounded, 'ID de cuenta', businessId),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 14, color: const Color(0xFF6B7280)),
        const SizedBox(width: 8),
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B7280),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF111827),
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
