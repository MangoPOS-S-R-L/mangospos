import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_tokens.dart';
import 'package:mangopos/core/config/plans_config.dart';
import 'package:mangopos/presentation/auth/widgets/auth_shell.dart';
import 'package:flutter_animate/flutter_animate.dart';
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

  static const _steps = <AuthShellStep>[
    AuthShellStep(title: 'Crear cuenta'),
    AuthShellStep(title: 'Agregar negocio'),
    AuthShellStep(title: 'Activando'),
  ];

  @override
  void initState() {
    super.initState();
    ref.read(registerStep1VmProvider.notifier).setSelectedPlan(widget.initialPlan);
    final state = ref.read(registerStep1VmProvider);
    _fullNameCtl = TextEditingController(text: state.fullName ?? '');
    _emailCtl = TextEditingController(text: state.email ?? '');
    _passwordCtl = TextEditingController(text: state.password ?? '');
  }

  @override
  void dispose() {
    _fullNameCtl.dispose();
    _emailCtl.dispose();
    _passwordCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(registerStep1VmProvider);
    final selectedPlan = PlansConfig.plans.firstWhere((p) => p.id == state.selectedPlan, orElse: () => PlansConfig.plans.first);
    final planLabel = selectedPlan.name;

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
              _eyebrow('Cuenta principal').animate().fadeIn(duration: 400.ms).slideX(begin: -0.1),
              const SizedBox(height: 18),
              Text(
                'Crea tu acceso',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  color: MangoTokens.foreground,
                ),
              ).animate().fadeIn(delay: 100.ms).slideX(begin: -0.1),
              const SizedBox(height: 10),
              Text(
                'Este usuario será el propietario inicial del negocio. Después podrás crear usuarios operativos con permisos separados.',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 15.5,
                  height: 1.6,
                  color: MangoTokens.mutedForeground,
                ),
              ).animate().fadeIn(delay: 200.ms).slideX(begin: -0.1),
              const SizedBox(height: 24),
              // Selector de Planes interactivo
              _FieldLabel('Elige el plan ideal para tu negocio')
                  .animate()
                  .fadeIn(delay: 300.ms),
              const SizedBox(height: 10),
              Container(
                constraints: const BoxConstraints(maxWidth: double.infinity),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  child: Row(
                    children: PlansConfig.plans.map((plan) {
                      final isSelected = plan.id == state.selectedPlan;
                      return Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                          width: 260,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFFFFF7F1) : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isSelected ? MangoTokens.primary : MangoTokens.border,
                              width: isSelected ? 2 : 1,
                            ),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: MangoTokens.primary.withValues(alpha: 0.1),
                                      blurRadius: 15,
                                      offset: const Offset(0, 5),
                                    )
                                  ]
                                : [],
                          ),
                          child: InkWell(
                            onTap: () {
                              ref.read(registerStep1VmProvider.notifier).setSelectedPlan(plan.id);
                            },
                            borderRadius: BorderRadius.circular(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (plan.isPopular)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    margin: const EdgeInsets.only(bottom: 12),
                                    decoration: BoxDecoration(
                                      color: MangoTokens.primary.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Text(
                                      'MÁS POPULAR',
                                      style: TextStyle(
                                        color: MangoTokens.primary,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                Text(
                                  plan.name,
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: MangoTokens.foreground,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  plan.price,
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: MangoTokens.secondaryForeground,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                ...plan.features.take(3).map((f) => Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Icon(Icons.check_circle, size: 14, color: MangoTokens.primary),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              f.title,
                                              style: GoogleFonts.plusJakartaSans(
                                                fontSize: 12,
                                                color: MangoTokens.mutedForeground,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    )),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ).animate().fadeIn(delay: 350.ms).slideX(begin: 0.1),
              const SizedBox(height: 30),
              _FieldLabel('Nombre del responsable').animate().fadeIn(delay: 400.ms),
              TextFormField(
                controller: _fullNameCtl,
                validator: _required,
                textInputAction: TextInputAction.next,
                decoration: _inputDecoration(
                  hint: 'Ej. Maria Rodriguez',
                  icon: Icons.badge_outlined,
                ),
              ).animate().fadeIn(delay: 450.ms).slideY(begin: 0.2),
              const SizedBox(height: 18),
              _FieldLabel('Correo de acceso').animate().fadeIn(delay: 500.ms),
              TextFormField(
                controller: _emailCtl,
                validator: (value) {
                  final email = (value ?? '').trim();
                  if (email.isEmpty) return 'Este campo es obligatorio';
                  if (!email.contains('@')) return 'Ingresa un correo válido';
                  return null;
                },
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                decoration: _inputDecoration(
                  hint: 'tu-negocio@correo.com',
                  icon: Icons.alternate_email_rounded,
                ),
              ).animate().fadeIn(delay: 550.ms).slideY(begin: 0.2),
              const SizedBox(height: 18),
              _FieldLabel('Contraseña').animate().fadeIn(delay: 600.ms),
              _PasswordField(controller: _passwordCtl).animate().fadeIn(delay: 650.ms).slideY(begin: 0.2),
              const SizedBox(height: 14),
              Text(
                'Mínimo 6 caracteres.',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12.5,
                  color: MangoTokens.mutedForeground,
                ),
              ).animate().fadeIn(delay: 700.ms),
              const SizedBox(height: 28),
              Row(
                children: [
                  Text(
                    '¿Ya tienes una cuenta?',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 14,
                      color: MangoTokens.mutedForeground,
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.go(AppRoutes.login),
                    child: const Text('Inicia sesión'),
                  ),
                ],
              ).animate().fadeIn(delay: 750.ms),
              const SizedBox(height: 8),
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
                  onPressed: _handleNext,
                  child: Text(
                    'Continuar',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ).animate().fadeIn(delay: 800.ms).slideY(begin: 0.2),
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
                AuthSummaryRow(label: 'Plan', value: planLabel),
                AuthSummaryRow(label: 'Prueba', value: '14 días gratis'),
                AuthSummaryRow(label: 'Acceso principal', value: 'Propietario'),
                AuthSummaryRow(label: 'Subdominio', value: 'tunegocio.mangopos.do'),
                AuthSummaryRow(
                  label: 'Permisos iniciales',
                  value: 'Administrador completo',
                  highlight: true,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _MutedBlock(
              title: 'Qué sigue',
              lines: const [
                'Registrar el negocio y su sucursal inicial.',
                'Elegir tipo de negocio.',
                'Definir el subdominio de acceso.',
                'Activar el espacio con configuración base.',
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _handleNext() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final vm = ref.read(registerStep1VmProvider.notifier);
    vm.setFullName(_fullNameCtl.text.trim());
    vm.setEmail(_emailCtl.text.trim());
    vm.setPassword(_passwordCtl.text);
    context.go(AppRoutes.registerStep2);
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Este campo es obligatorio';
    }
    return null;
  }

  Widget _eyebrow(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7F1),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFFFFE3CD)),
        ),
        child: Text(
          text,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: MangoTokens.primary,
          ),
        ),
      );
}

class _FieldLabel extends StatelessWidget {
  final String text;

  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: MangoTokens.secondaryForeground,
        ),
      ),
    );
  }
}

class _PasswordField extends StatefulWidget {
  final TextEditingController controller;

  const _PasswordField({required this.controller});

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
      validator: (value) {
        if ((value ?? '').length < 6) return 'Minimo 6 caracteres';
        return null;
      },
      autofillHints: const [AutofillHints.newPassword],
      decoration: _inputDecoration(
        hint: 'Protege la cuenta principal',
        icon: Icons.lock_outline_rounded,
        suffix: IconButton(
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(
            _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: MangoTokens.mutedForeground,
          ),
        ),
      ),
    );
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
