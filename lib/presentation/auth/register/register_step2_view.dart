import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_tokens.dart';
import 'package:mangopos/data/models/billing_plan.dart';
import 'package:mangopos/presentation/auth/register/business_registration_catalog.dart';
import 'package:mangopos/presentation/auth/register/register_step1_viewmodel.dart';
import 'package:mangopos/presentation/auth/widgets/auth_shell.dart';
import 'package:mangopos/presentation/billing/providers/billing_providers.dart';
import 'register_step2_viewmodel.dart';

class RegisterStep2View extends ConsumerStatefulWidget {
  const RegisterStep2View({super.key});

  @override
  ConsumerState<RegisterStep2View> createState() => _RegisterStep2ViewState();
}

class _RegisterStep2ViewState extends ConsumerState<RegisterStep2View> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _businessCtl;
  late final TextEditingController _branchCtl;
  late final TextEditingController _addressCtl;
  late final TextEditingController _phoneCtl;
  late String _country;
  late String _businessType;
  late String _currency;
  late String _businessSize;

  static const _steps = <AuthShellStep>[
    AuthShellStep(title: 'Crear cuenta', complete: true),
    AuthShellStep(title: 'Agregar negocio'),
    AuthShellStep(title: 'Activando'),
  ];

  static const _countries = <String>[
    'República Dominicana',
    'Estados Unidos',
    'México',
    'Colombia',
    'Perú',
    'Chile',
    'Argentina',
    'España',
  ];

  static const _currencyOptions = <String>[
    'Peso Dominicano (DOP)',
    'Dólar estadounidense (USD)',
    'Peso Mexicano (MXN)',
  ];

  static const _businessSizeOptions = <String>[
    'Micro',
    'Pequeño',
    'Mediano',
    'Grande',
  ];

  @override
  void initState() {
    super.initState();
    final state = ref.read(registerStep2VmProvider);
    final notifier = ref.read(registerStep2VmProvider.notifier);
    _businessCtl = TextEditingController(text: state.businessName);
    _branchCtl = TextEditingController(text: state.branchName);
    _addressCtl = TextEditingController(text: state.address);
    _phoneCtl = TextEditingController(text: state.phone);
    _country = _countries.contains(state.country)
        ? state.country
        : _countries.first;
    _businessType = state.businessType;
    _currency = _currencyOptions.first;
    _businessSize = _businessSizeOptions[1];
    // Subdominio se autogenera en el viewmodel a partir del nombre.
    notifier.setSubdomain('');

    _businessCtl.addListener(() => setState(() {}));
    _branchCtl.addListener(() => setState(() {}));
    _addressCtl.addListener(() => setState(() {}));
    _phoneCtl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _businessCtl.dispose();
    _branchCtl.dispose();
    _addressCtl.dispose();
    _phoneCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.read(registerStep2VmProvider.notifier);
    final selectedType = businessTypeByDbValue(_businessType);
    final step1 = ref.watch(registerStep1VmProvider);
    final step2 = ref.watch(registerStep2VmProvider);
    final plansAsync = ref.watch(availablePlansProvider);
    final plans = plansAsync.valueOrNull ?? const <BillingPlan>[];
    final BillingPlan? selectedPlan = plans.isEmpty
        ? null
        : plans.firstWhere(
            (p) => p.id == step1.selectedPlanId,
            orElse: () => plans.first,
          );
    final summaryBranch = _branchCtl.text.trim().isEmpty
        ? 'Sucursal Principal'
        : _branchCtl.text.trim();

    return AuthShell(
      brandSubtitle: 'Registro del negocio',
      steps: _steps,
      currentStep: 1,
      main: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _eyebrow('Paso 2 de 3'),
              const SizedBox(height: 10),
              Text(
                'Configura tu empresa',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  color: MangoTokens.foreground,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Completa los datos principales del negocio y define el subdominio con el que entrarás a MangoPOS.',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 15.5,
                  height: 1.55,
                  color: MangoTokens.mutedForeground,
                ),
              ),
              const SizedBox(height: 28),
              _FieldLabel('Nombre del negocio'),
              TextFormField(
                controller: _businessCtl,
                validator: _required,
                textInputAction: TextInputAction.next,
                decoration: _inputDecoration(
                  hint: 'Ej. Restaurante El Mango',
                  icon: Icons.storefront_rounded,
                ),
              ),
              const SizedBox(height: 22),
              _FieldLabel('Tipo de negocio'),
              DropdownButtonFormField<String>(
                initialValue: _businessType,
                items: businessTypeOptions
                    .map(
                      (option) => DropdownMenuItem(
                        value: option.dbValue,
                        child: Text(option.label),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _businessType = value);
                },
                decoration: _inputDecoration(
                  hint: 'Selecciona el tipo de negocio',
                  icon: selectedType.icon,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _FieldLabel('País'),
                        DropdownButtonFormField<String>(
                          initialValue: _country,
                          items: _countries
                              .map(
                                (country) => DropdownMenuItem(
                                  value: country,
                                  child: Text(country),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() => _country = value);
                          },
                          decoration: _inputDecoration(
                            hint: 'Selecciona un país',
                            icon: Icons.public_rounded,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _FieldLabel('Moneda'),
                        DropdownButtonFormField<String>(
                          initialValue: _currency,
                          items: _currencyOptions
                              .map(
                                (currency) => DropdownMenuItem(
                                  value: currency,
                                  child: Text(currency),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() => _currency = value);
                          },
                          decoration: _inputDecoration(
                            hint: 'Elige la divisa',
                            icon: Icons.monetization_on_outlined,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _FieldLabel('Tamaño del negocio'),
                        DropdownButtonFormField<String>(
                          initialValue: _businessSize,
                          items: _businessSizeOptions
                              .map(
                                (size) => DropdownMenuItem(
                                  value: size,
                                  child: Text(size),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() => _businessSize = value);
                          },
                          decoration: _inputDecoration(
                            hint: 'Selecciona una opción',
                            icon: Icons.pie_chart_outline_rounded,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _FieldLabel('Teléfono del negocio'),
                        TextFormField(
                          controller: _phoneCtl,
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.next,
                          decoration: _inputDecoration(
                            hint: '+1 809 555 0000',
                            icon: Icons.phone_outlined,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              _FieldLabel('Dirección base del negocio'),
              TextFormField(
                controller: _addressCtl,
                validator: _required,
                minLines: 3,
                maxLines: 5,
                decoration: _inputDecoration(
                  hint: 'Dirección operativa y fiscal.',
                  icon: Icons.pin_drop_outlined,
                ),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () => context.go(AppRoutes.register),
                    icon: const Icon(Icons.arrow_back_rounded),
                    label: const Text('Atrás'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: MangoTokens.secondaryForeground,
                      side: const BorderSide(color: MangoTokens.border),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    height: 54,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: MangoTokens.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 26),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () {
                        if (!(_formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        if (selectedPlan == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'No hay planes disponibles. Regresa al paso 1.',
                              ),
                            ),
                          );
                          return;
                        }
                        if (!step2.consentGranted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Debes autorizar el cobro recurrente para continuar.',
                              ),
                            ),
                          );
                          return;
                        }
                        vm.setBusinessName(_businessCtl.text.trim());
                        vm.setBranch(_branchCtl.text.trim());
                        vm.setBusinessType(_businessType);
                        vm.setCountry(_country);
                        vm.setPhone(_phoneCtl.text.trim());
                        vm.setAddress(_addressCtl.text.trim());
                        context.go(AppRoutes.registerSetup);
                      },
                      child: Text(
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
            ],
          ),
        ),
      ),
      side: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Resumen de empresa',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: MangoTokens.foreground,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Tu negocio en MangoPOS',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: MangoTokens.mutedForeground,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Revisa la información principal antes de terminar la configuración inicial.',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 14,
                height: 1.6,
                color: MangoTokens.mutedForeground,
              ),
            ),
            const SizedBox(height: 22),
            if (selectedPlan != null) ...[
              _PlanSummaryCard(plan: selectedPlan),
              const SizedBox(height: 18),
            ],
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: MangoTokens.border),
              ),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    _DetailRow(
                      label: 'Negocio',
                      value: _businessCtl.text.trim().isEmpty
                          ? 'Pendiente'
                          : _businessCtl.text.trim(),
                    ),
                    const SizedBox(height: 8),
                    _DetailRow(label: 'Tipo', value: selectedType.label),
                    const SizedBox(height: 8),
                    _DetailRow(label: 'Sucursal', value: summaryBranch),
                    const SizedBox(height: 8),
                    _DetailRow(label: 'País', value: _country),
                    const SizedBox(height: 8),
                    _DetailRow(label: 'Moneda', value: _currency),
                    const SizedBox(height: 8),
                    _DetailRow(label: 'Tamaño', value: _businessSize),
                  ],
                ),
              ),
            ),
            if (selectedPlan != null) ...[
              const SizedBox(height: 18),
              _TotalSummaryCard(plan: selectedPlan),
            ],
            const SizedBox(height: 18),
            _ConsentBlock(
              plan: selectedPlan,
              accepted: step2.consentGranted,
              onChanged: (v) => vm.setConsentGranted(v),
            ),
          ],
        ),
      ),
    );
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

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _DetailRow({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final valueColor = highlight ? MangoTokens.primary : MangoTokens.foreground;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: MangoTokens.mutedForeground,
            ),
          ),
        ),
        Text(
          value,
          textAlign: TextAlign.right,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            fontWeight: highlight ? FontWeight.w700 : FontWeight.w600,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

class _PlanSummaryCard extends StatelessWidget {
  final BillingPlan plan;

  const _PlanSummaryCard({required this.plan});

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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7F1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.star_rounded,
                    color: MangoTokens.primary,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plan.name,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: MangoTokens.foreground,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        plan.description ?? 'Plan para tu suscripción.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 13,
                          height: 1.4,
                          color: MangoTokens.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${plan.formattedPrice}/mes',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: MangoTokens.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalSummaryCard extends StatelessWidget {
  final BillingPlan plan;

  const _TotalSummaryCard({required this.plan});

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
              'Después de ${plan.trialDays} días',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: MangoTokens.mutedForeground,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              plan.formattedPrice,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: MangoTokens.foreground,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Cobro mensual recurrente',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                color: MangoTokens.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bloque de consentimiento explícito al cobro recurrente (PRD §10.5).
/// Required — sin esto el submit del Step 3 lanza error con mensaje claro.
class _ConsentBlock extends StatelessWidget {
  final BillingPlan? plan;
  final bool accepted;
  final ValueChanged<bool> onChanged;

  const _ConsentBlock({
    required this.plan,
    required this.accepted,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final priceLine = plan == null
        ? 'el precio del plan elegido cada mes'
        : '${plan!.formattedPrice}/mes a partir del día ${plan!.trialDays + 1}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accepted ? const Color(0xFFF6FBF8) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: accepted ? MangoTokens.success : MangoTokens.border,
          width: accepted ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: accepted,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: MangoTokens.success,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Autorizo el cobro recurrente',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: MangoTokens.foreground,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Autorizo a MangoPOS a cobrar mi tarjeta automáticamente '
                    'por $priceLine. Puedo cambiar de plan o cancelar cuando '
                    'quiera desde Configuración → Suscripción y pagos.',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
                      height: 1.45,
                      color: MangoTokens.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// (_extractPrice eliminado — los precios ahora vienen formateados desde BillingPlan.)

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

