import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_tokens.dart';
import 'package:mangopos/presentation/auth/register/business_registration_catalog.dart';
import 'package:mangopos/presentation/auth/register/register_step2_viewmodel.dart';
import 'package:mangopos/presentation/auth/widgets/auth_shell.dart';

class RegisterStep3View extends ConsumerStatefulWidget {
  const RegisterStep3View({super.key});

  @override
  ConsumerState<RegisterStep3View> createState() => _RegisterStep3ViewState();
}

class _RegisterStep3ViewState extends ConsumerState<RegisterStep3View> {
  bool _completed = false;
  bool _requiresEmailConfirmation = false;
  String? _successMessage;
  String? _error;
  Timer? _redirectTimer;
  // Candado anti doble-submit: `_runSetup` se dispara desde initState y desde
  // dos botones "Reintentar". Sin este flag, dos taps rápidos lanzarían dos
  // `submitAll()` en paralelo y podrían crear DOS negocios para el mismo dueño.
  bool _running = false;

  static const _steps = <AuthShellStep>[
    AuthShellStep(title: 'Crear cuenta', complete: true),
    AuthShellStep(title: 'Agregar negocio', complete: true),
    AuthShellStep(title: 'Activando'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runSetup());
  }

  @override
  void dispose() {
    _redirectTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final businessState = ref.watch(registerStep2VmProvider);
    final businessType = businessTypeByDbValue(businessState.businessType);
    final domainPreview =
        ref.read(registerStep2VmProvider.notifier).buildDomainPreview();

    return AuthShell(
      brandSubtitle: 'Activación del negocio',
      steps: _steps,
      currentStep: 2,
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
                  color: _error != null
                      ? const Color(0xFFFFF3F3)
                      : const Color(0xFFFFF7F1),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  _completed
                      ? (_requiresEmailConfirmation
                          ? Icons.mark_email_read_outlined
                          : Icons.check_rounded)
                      : _error != null
                          ? Icons.error_outline_rounded
                          : Icons.sync_rounded,
                  size: 42,
                  color: _completed
                      ? MangoTokens.success
                      : _error != null
                          ? MangoTokens.destructive
                          : MangoTokens.primary,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                _error != null
                    ? 'No pudimos completar la activación'
                    : _completed
                        ? (_requiresEmailConfirmation
                            ? 'Cuenta creada, falta confirmar correo'
                            : 'Tu negocio está listo')
                        : 'Estamos activando tu espacio',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: MangoTokens.foreground,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _error != null
                    ? _error!
                    : _completed
                        ? (_successMessage ??
                            'Todo quedó creado correctamente. En unos segundos entrarás al panel principal.')
                        : 'Creando configuración base, métodos de pago, moneda e impuestos para ${businessState.businessName}.',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 15.5,
                  height: 1.6,
                  color: MangoTokens.mutedForeground,
                ),
              ),
              const SizedBox(height: 22),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 10,
                  value: _completed
                      ? 1
                      : _error != null
                          ? 0.42
                          : null,
                  color: _error != null
                      ? MangoTokens.destructive
                      : MangoTokens.primary,
                  backgroundColor: MangoTokens.muted,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _completed
                    ? (_requiresEmailConfirmation
                        ? 'Revisa tu correo y luego inicia sesión.'
                        : 'Entrando al panel...')
                    : _error != null
                        ? 'Corrige y vuelve a intentar.'
                        : 'Preparando $domainPreview',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: _error != null
                      ? MangoTokens.destructive
                      : MangoTokens.info,
                ),
              ),
              if (_error != null || (_completed && _requiresEmailConfirmation)) ...[
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => context.go(AppRoutes.login),
                      icon: const Icon(Icons.login_rounded),
                      label: Text(
                        _completed && _requiresEmailConfirmation
                            ? 'Ir a iniciar sesión'
                            : 'Volver al login',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: MangoTokens.secondaryForeground,
                        side: const BorderSide(color: MangoTokens.border),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                      ),
                    ),
                    if (_error != null)
                      ElevatedButton.icon(
                        onPressed: _runSetup,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Reintentar'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: MangoTokens.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 14,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      side: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AuthSummaryCard(
              title: 'Resumen',
              children: [
                AuthSummaryRow(
                  label: 'Negocio',
                  value: businessState.businessName.trim().isEmpty
                      ? 'Pendiente'
                      : businessState.businessName.trim(),
                ),
                AuthSummaryRow(label: 'Tipo', value: businessType.label),
                AuthSummaryRow(
                  label: 'Dominio',
                  value: domainPreview,
                  highlight: true,
                ),
                AuthSummaryRow(
                  label: 'Sucursal',
                  value: businessState.branchName.trim().isEmpty
                      ? 'Sucursal Principal'
                      : businessState.branchName.trim(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _MutedBlock(
              title: _completed
                  ? (_requiresEmailConfirmation ? 'Confirmación pendiente' : 'Listo')
                  : 'Activación',
              lines: [
                'Configuración base del negocio.',
                'Moneda DOP e ITBIS inicial.',
                'Zona y almacén principal.',
                _completed
                    ? (_requiresEmailConfirmation
                        ? 'Cuenta creada. Falta confirmar el correo del propietario.'
                        : 'Acceso creado correctamente.')
                    : 'Creación del acceso propietario.',
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runSetup() async {
    if (!mounted || _running) return;
    _running = true;
    setState(() {
      _completed = false;
      _requiresEmailConfirmation = false;
      _successMessage = null;
      _error = null;
    });
    try {
      final result = await ref
          .read(registerStep2VmProvider.notifier)
          .submitAll(requestOtp: _promptForOtpCode);
      if (!mounted) return;
      setState(() {
        _completed = true;
        _requiresEmailConfirmation = result.requiresEmailConfirmation;
        _successMessage = result.message;
      });
      if (!result.requiresEmailConfirmation) {
        // PRD-Azul §8.1 — tras crear cuenta exitosa, no vamos al dashboard
        // directo: pasamos por Step 4 (registro de tarjeta) para no perder
        // el card-on-file. El usuario puede saltar pero queda advertido del
        // riesgo de suspensión al día 14.
        _redirectTimer = Timer(const Duration(milliseconds: 900), () {
          if (mounted) context.go(AppRoutes.registerPaymentMethod);
        });
      }
    } catch (error) {
      if (!mounted) return;
      final errorMsg = error.toString().replaceFirst('Exception: ', '');
      setState(() {
        _completed = false;
        _requiresEmailConfirmation = false;
        _successMessage = null;
        _error = errorMsg;
      });
      // Show error modal
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            icon: const Icon(Icons.error_outline_rounded,
                color: Colors.red, size: 44),
            title: const Text('Error en el registro'),
            content: Text(
              errorMsg,
              style: const TextStyle(fontSize: 15, height: 1.4),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  context.go(AppRoutes.register);
                },
                child: const Text('Volver al inicio'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: MangoTokens.primary,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _runSetup();
                },
                child: const Text('Reintentar'),
              ),
            ],
          ),
        );
      }
    } finally {
      _running = false;
    }
  }

  /// Modal de verificación de correo cuando el email ya tiene cuenta.
  /// Devuelve el código tipeado o `null` si el usuario cancela. La lógica
  /// real de enviar y validar el OTP vive en el viewmodel — este widget
  /// solo recolecta el código de la UI.
  Future<String?> _promptForOtpCode(String email) async {
    if (!mounted) return null;
    final controller = TextEditingController();
    String? errorText;

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              icon: const Icon(Icons.mark_email_read_outlined,
                  color: MangoTokens.primary, size: 44),
              title: const Text('Verifica tu correo'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Ese correo ya tiene una cuenta. Te enviamos un código '
                    'de 6 dígitos a $email — pégalo aquí para confirmar que '
                    'eres tú y continuar con el registro de tu negocio.',
                    style: const TextStyle(fontSize: 14, height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 6,
                    ),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: '······',
                      hintStyle: const TextStyle(
                        letterSpacing: 6,
                        color: Color(0xFFCBD5E1),
                      ),
                      errorText: errorText,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('Cancelar'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: MangoTokens.primary,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    final code = controller.text.trim();
                    if (code.length != 6 ||
                        int.tryParse(code) == null) {
                      setLocal(() => errorText = 'El código son 6 dígitos.');
                      return;
                    }
                    Navigator.of(ctx).pop(code);
                  },
                  child: const Text('Verificar'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();
    return result;
  }
}

class _MutedBlock extends StatelessWidget {
  final String title;
  final List<String> lines;

  const _MutedBlock({required this.title, required this.lines});

  @override
  Widget build(BuildContext context) {
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
            Text(
              title,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: MangoTokens.foreground,
              ),
            ),
            const SizedBox(height: 12),
            ...lines.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  '• $line',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13.5,
                    height: 1.55,
                    color: MangoTokens.mutedForeground,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
