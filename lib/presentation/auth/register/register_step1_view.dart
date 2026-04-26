import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_tokens.dart';
import 'package:mangopos/core/config/plans_config.dart';
import 'package:mangopos/presentation/auth/widgets/auth_shell.dart';
import 'register_step1_viewmodel.dart';

class RegisterStep1View extends ConsumerStatefulWidget {
  final String? initialPlan;

  const RegisterStep1View({super.key, this.initialPlan});

  @override
  ConsumerState<RegisterStep1View> createState() => _RegisterStep1ViewState();
}

class _RegisterStep1ViewState extends ConsumerState<RegisterStep1View> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _fullNameCtl;
  late final TextEditingController _emailCtl;
  late final TextEditingController _passwordCtl;
  late final TextEditingController _confirmCtl;
  bool _termsAccepted = false;
  bool _submitting = false;

  static const _steps = <AuthShellStep>[
    AuthShellStep(title: 'Crear cuenta'),
    AuthShellStep(title: 'Agregar negocio'),
    AuthShellStep(title: 'Activando'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(registerStep1VmProvider.notifier)
          .setSelectedPlan(widget.initialPlan);
    });
    final state = ref.read(registerStep1VmProvider);
    _fullNameCtl = TextEditingController(text: state.fullName ?? '');
    _emailCtl = TextEditingController(text: state.email ?? '');
    _passwordCtl = TextEditingController(text: state.password ?? '');
    _confirmCtl = TextEditingController();
  }

  @override
  void dispose() {
    _fullNameCtl.dispose();
    _emailCtl.dispose();
    _passwordCtl.dispose();
    _confirmCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final planNotifier = ref.read(registerStep1VmProvider.notifier);
    final state = ref.watch(registerStep1VmProvider);
    final selectedPlan = PlansConfig.plans.firstWhere(
      (p) => p.id == state.selectedPlan,
      orElse: () => PlansConfig.plans.first,
    );
    final afterTrialValue = _extractPrice(selectedPlan.price);
    final featureHighlights = selectedPlan.features
        .take(4)
        .map((feature) => feature.title)
        .toList();

    return AuthShell(
      brandSubtitle: 'Onboarding de negocios en MangoPOS',
      steps: _steps,
      currentStep: 0,
      main: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              _FieldLabel('Nombre completo'),
              TextFormField(
                controller: _fullNameCtl,
                validator: _required,
                textInputAction: TextInputAction.next,
                decoration: _inputDecoration(
                  hint: 'Ej. María Rodríguez',
                  icon: Icons.badge_outlined,
                ),
              ),
              const SizedBox(height: 18),
              _FieldLabel('Correo electrónico'),
              TextFormField(
                controller: _emailCtl,
                validator: (value) {
                  final email = (value ?? '').trim();
                  if (email.isEmpty) return 'Este campo es obligatorio';
                  final emailRegex = RegExp(
                      r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');
                  if (!emailRegex.hasMatch(email)) {
                    return 'Ingresa un correo válido (ej: tu@empresa.com)';
                  }
                  return null;
                },
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                decoration: _inputDecoration(
                  hint: 'tu@empresa.com',
                  icon: Icons.alternate_email_rounded,
                ),
              ),
              const SizedBox(height: 18),
              _FieldLabel('Teléfono'),
              TextFormField(
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                decoration: _inputDecoration(
                  hint: '+1 809 555 0000',
                  icon: Icons.phone_outlined,
                ),
              ),
              const SizedBox(height: 18),
              _FieldLabel('Contraseña'),
              _PasswordField(controller: _passwordCtl),
              const SizedBox(height: 18),
              _FieldLabel('Confirmar contraseña'),
              _PasswordField(
                controller: _confirmCtl,
                hint: 'Repite tu contraseña',
                validator: (value) {
                  if ((value ?? '').isEmpty) return 'Este campo es obligatorio';
                  if (value != _passwordCtl.text) {
                    return 'Las contraseñas no coinciden';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: _termsAccepted,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    onChanged: (value) {
                      setState(() => _termsAccepted = value ?? false);
                    },
                  ),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        text: 'Acepto los ',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 13,
                          color: MangoTokens.mutedForeground,
                        ),
                        children: [
                          TextSpan(
                            text: 'Términos y Condiciones',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: MangoTokens.primary,
                            ),
                          ),
                          TextSpan(
                            text: ' y la Política de Privacidad',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: MangoTokens.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: MangoTokens.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _submitting ? null : _handleNext,
                  child: _submitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          'Continuar',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
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
            Text(
              'Selecciona tu plan',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: MangoTokens.secondaryForeground,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Plan para tu cuenta',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: MangoTokens.foreground,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Solo mostramos los planes disponibles en la web. Todos incluyen 14 días de prueba.',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 14,
                height: 1.6,
                color: MangoTokens.mutedForeground,
              ),
            ),
            const SizedBox(height: 22),
            Column(
              children: PlansConfig.plans.map((plan) {
                final isSelected = plan.id == selectedPlan.id;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _PlanOptionCard(
                    plan: plan,
                    selected: isSelected,
                    onTap: () => planNotifier.setSelectedPlan(plan.id),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 18),
            _PlanDetailCard(plan: selectedPlan),
            const SizedBox(height: 18),
            _PlanTotalCard(
              afterTrial: afterTrialValue,
              planPrice: selectedPlan.price,
              highlights: featureHighlights,
            ),
          ],
        ),
      ),
    );
  }

  void _handleNext() {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) {
      _showError('Revisa los campos marcados en rojo antes de continuar.');
      return;
    }
    if (!_termsAccepted) {
      _showError('Debes aceptar los Términos y Condiciones para continuar.');
      return;
    }
    setState(() => _submitting = true);
    final vm = ref.read(registerStep1VmProvider.notifier);
    vm.setFullName(_fullNameCtl.text.trim());
    vm.setEmail(_emailCtl.text.trim());
    vm.setPassword(_passwordCtl.text);
    context.go(AppRoutes.registerStep2);
  }

  void _showError(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 40),
        title: const Text('Atención'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Este campo es obligatorio';
    }
    return null;
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;

  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: GoogleFonts.plusJakartaSans(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF66718A),
        ),
      ),
    );
  }
}

class _PasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final String? Function(String?)? validator;

  const _PasswordField({
    required this.controller,
    this.hint = 'Protege la cuenta principal',
    this.validator,
  });

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      obscureText: _obscure,
      validator:
          widget.validator ??
          (value) {
            final pwd = value ?? '';
            if (pwd.length < 8) return 'Mínimo 8 caracteres';
            if (!pwd.contains(RegExp(r'[A-Z]'))) {
              return 'Debe contener al menos una mayúscula';
            }
            if (!pwd.contains(RegExp(r'[0-9]'))) {
              return 'Debe contener al menos un número';
            }
            return null;
          },
      autofillHints: const [AutofillHints.newPassword],
      decoration: _inputDecoration(
        hint: widget.hint,
        icon: Icons.lock_outline_rounded,
        suffix: IconButton(
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(
            _obscure
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            color: MangoTokens.mutedForeground,
          ),
        ),
      ),
    );
  }
}

class _PlanOptionCard extends StatelessWidget {
  final MangoPlan plan;
  final bool selected;
  final VoidCallback onTap;

  const _PlanOptionCard({
    required this.plan,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? MangoTokens.primary : MangoTokens.border;
    final background = selected ? const Color(0xFFFFF5EE) : Colors.white;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: MangoTokens.primary.withOpacity(0.12),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked,
                  color: selected
                      ? MangoTokens.primary
                      : MangoTokens.mutedForeground,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plan.name,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: MangoTokens.foreground,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        plan.description,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 13,
                          height: 1.5,
                          color: MangoTokens.secondaryForeground,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      plan.price,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: MangoTokens.foreground,
                      ),
                    ),
                    if (selected) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF1E1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'SELECCIONADO',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: MangoTokens.primary,
                          ),
                        ),
                      ),
                    ],
                    if (!selected) const SizedBox(height: 20),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlanDetailCard extends StatelessWidget {
  final MangoPlan plan;

  const _PlanDetailCard({required this.plan});

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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7F1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.star_rounded,
                color: MangoTokens.primary,
                size: 28,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Resumen del plan ${plan.name}',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: MangoTokens.foreground,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Facturación mensual',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      color: MangoTokens.secondaryForeground,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              plan.price,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: MangoTokens.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanTotalCard extends StatelessWidget {
  final String afterTrial;
  final String planPrice;
  final List<String> highlights;

  const _PlanTotalCard({
    required this.afterTrial,
    required this.planPrice,
    required this.highlights,
  });

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
            Row(
              children: [
                Text(
                  'Total ahora',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: MangoTokens.mutedForeground,
                  ),
                ),
                const Spacer(),
                Text(
                  'US\$0.00',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: MangoTokens.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(color: MangoTokens.border),
            const SizedBox(height: 12),
            Text(
              'Después de 14 días',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: MangoTokens.mutedForeground,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              afterTrial,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: MangoTokens.foreground,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              planPrice,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                color: MangoTokens.mutedForeground,
              ),
            ),
            const SizedBox(height: 14),
            ...highlights.map((feature) => _PlanFeatureRow(feature)),
          ],
        ),
      ),
    );
  }
}

class _PlanFeatureRow extends StatelessWidget {
  final String feature;

  const _PlanFeatureRow(this.feature);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          const Icon(Icons.check_circle, size: 18, color: Colors.green),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              feature,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                color: MangoTokens.mutedForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

InputDecoration _inputDecoration({
  required String hint,
  required IconData icon,
  Widget? suffix,
}) {
  return InputDecoration(
    hintText: hint,
    hintStyle: GoogleFonts.plusJakartaSans(
      color: MangoTokens.mutedForeground,
      fontSize: 14,
    ),
    prefixIcon: Icon(icon, color: MangoTokens.mutedForeground),
    suffixIcon: suffix,
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: MangoTokens.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: MangoTokens.primary, width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: MangoTokens.destructive),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: MangoTokens.destructive, width: 1.5),
    ),
  );
}

String _extractPrice(String raw) {
  final match = RegExp(r'US\$[\d.,]+').firstMatch(raw);
  if (match != null) {
    return match.group(0)!;
  }
  return raw;
}
