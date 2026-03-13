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
  String? _error;
  Timer? _redirectTimer;

  static const _steps = <AuthShellStep>[
    AuthShellStep(title: 'Crear cuenta', complete: true),
    AuthShellStep(title: 'Agregar negocio', complete: true),
    AuthShellStep(title: 'Activando'),
  ];

  @override
  void initState() {
    super.initState();
    Future.microtask(_runSetup);
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
                      ? Icons.check_rounded
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
                        ? 'Tu negocio está listo'
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
                        ? 'Todo quedó creado correctamente. En unos segundos entrarás al panel principal.'
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
                    ? 'Entrando al panel...'
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
              if (_error != null) ...[
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => context.go(AppRoutes.registerStep2),
                      icon: const Icon(Icons.arrow_back_rounded),
                      label: const Text('Volver'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: MangoTokens.secondaryForeground,
                        side: const BorderSide(color: MangoTokens.border),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                      ),
                    ),
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
              title: _completed ? 'Listo' : 'Activación',
              lines: [
                'Configuración base del negocio.',
                'Moneda DOP e ITBIS inicial.',
                'Zona y almacén principal.',
                _completed
                    ? 'Acceso creado correctamente.'
                    : 'Creación del acceso propietario.',
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runSetup() async {
    setState(() {
      _completed = false;
      _error = null;
    });
    try {
      await ref.read(registerStep2VmProvider.notifier).submitAll();
      if (!mounted) return;
      setState(() {
        _completed = true;
      });
      _redirectTimer = Timer(const Duration(milliseconds: 1100), () {
        if (mounted) context.go(AppRoutes.dashboard);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _completed = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
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
