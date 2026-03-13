import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_tokens.dart';
import 'package:mangopos/presentation/auth/register/business_registration_catalog.dart';
import 'package:mangopos/presentation/auth/widgets/auth_shell.dart';
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
  late final TextEditingController _subdomainCtl;
  late final TextEditingController _addressCtl;
  late final TextEditingController _phoneCtl;
  late String _country;
  late String _businessType;
  bool _subdomainTouched = false;
  bool _programmaticSubdomainUpdate = false;

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

  @override
  void initState() {
    super.initState();
    final state = ref.read(registerStep2VmProvider);
    _businessCtl = TextEditingController(text: state.businessName);
    _branchCtl = TextEditingController(text: state.branchName);
    _subdomainCtl = TextEditingController(text: state.subdomain);
    _addressCtl = TextEditingController(text: state.address);
    _phoneCtl = TextEditingController(text: state.phone);
    _country = _countries.contains(state.country) ? state.country : _countries.first;
    _businessType = state.businessType;

    _businessCtl.addListener(() {
      if (_subdomainTouched) return;
      _setSubdomainProgrammatically(_slugify(_businessCtl.text));
      setState(() {});
    });
    _subdomainCtl.addListener(() {
      if (_programmaticSubdomainUpdate) return;
      _subdomainTouched = true;
      setState(() {});
    });
    _branchCtl.addListener(() => setState(() {}));
    _phoneCtl.addListener(() => setState(() {}));
    _addressCtl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _businessCtl.dispose();
    _branchCtl.dispose();
    _subdomainCtl.dispose();
    _addressCtl.dispose();
    _phoneCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.read(registerStep2VmProvider.notifier);
    final selectedType = businessTypeByDbValue(_businessType);
    final domainPreview =
        '${_slugify(_subdomainCtl.text).isEmpty ? 'tunegocio' : _slugify(_subdomainCtl.text)}.mangopos.do';
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
              _eyebrow('Datos del negocio'),
              const SizedBox(height: 18),
              Text(
                'Configura tu negocio',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  color: MangoTokens.foreground,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Define el nombre, el tipo de operación y el subdominio que usarás más adelante para entrar a tu espacio.',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 15.5,
                  height: 1.6,
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
                  hint: 'Ej. Mango Bistró',
                  icon: Icons.storefront_rounded,
                ),
              ),
              const SizedBox(height: 18),
              _FieldLabel('Sucursal inicial'),
              TextFormField(
                controller: _branchCtl,
                textInputAction: TextInputAction.next,
                decoration: _inputDecoration(
                  hint: 'Principal, Piantini, etc.',
                  icon: Icons.location_city_outlined,
                ),
              ),
              const SizedBox(height: 18),
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
                  hint: 'Selecciona un tipo',
                  icon: selectedType.icon,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7F1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFFFE3CD)),
                ),
                child: Text(
                  selectedType.subtitle,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13.5,
                    height: 1.55,
                    color: MangoTokens.secondaryForeground,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              _FieldLabel('Subdominio de acceso'),
              TextFormField(
                controller: _subdomainCtl,
                validator: _validateSubdomain,
                textInputAction: TextInputAction.next,
                decoration: _inputDecoration(
                  hint: 'mangobistro',
                  icon: Icons.language_rounded,
                  suffix: Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: Center(
                      widthFactor: 1,
                      child: Text(
                        '.mangopos.do',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: MangoTokens.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Vista previa: $domainPreview',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: MangoTokens.info,
                ),
              ),
              const SizedBox(height: 18),
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
                        _FieldLabel('Teléfono (opcional)'),
                        TextFormField(
                          controller: _phoneCtl,
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.next,
                          decoration: _inputDecoration(
                            hint: '8095550101',
                            icon: Icons.phone_outlined,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
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
                        horizontal: 16,
                        vertical: 15,
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
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () {
                        if (!(_formKey.currentState?.validate() ?? false)) return;
                        vm.setBusinessName(_businessCtl.text.trim());
                        vm.setBranch(_branchCtl.text.trim());
                        vm.setBusinessType(_businessType);
                        vm.setCountry(_country);
                        vm.setPhone(_phoneCtl.text.trim());
                        vm.setAddress(_addressCtl.text.trim());
                        vm.setSubdomain(_slugify(_subdomainCtl.text));
                        context.go(AppRoutes.registerSetup);
                      },
                      child: Text(
                        'Activar negocio',
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
            AuthSummaryCard(
              title: 'Resumen',
              children: [
                AuthSummaryRow(
                  label: 'Negocio',
                  value: _businessCtl.text.trim().isEmpty
                      ? 'Pendiente'
                      : _businessCtl.text.trim(),
                ),
                AuthSummaryRow(label: 'Tipo', value: selectedType.label),
                AuthSummaryRow(label: 'Sucursal', value: summaryBranch),
                AuthSummaryRow(
                  label: 'Dominio',
                  value: domainPreview,
                  highlight: true,
                ),
                AuthSummaryRow(label: 'País', value: _country),
              ],
            ),
            const SizedBox(height: 16),
            _MutedBlock(
              title: 'Se crea automáticamente',
              lines: const [
                'Métodos de pago base.',
                'Moneda DOP e ITBIS inicial.',
                'Zona y almacén principal.',
                'Acceso del propietario.',
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _setSubdomainProgrammatically(String value) {
    _programmaticSubdomainUpdate = true;
    _subdomainCtl.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _programmaticSubdomainUpdate = false;
  }

  String _slugify(String input) {
    final normalized = input
        .trim()
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ñ', 'n');
    return normalized
        .replaceAll('.mangopos.do', '')
        .replaceAll(RegExp(r'[^a-z0-9-]'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Este campo es obligatorio';
    }
    return null;
  }

  String? _validateSubdomain(String? value) {
    final subdomain = _slugify(value ?? '');
    if (subdomain.isEmpty) return 'Define un subdominio';
    if (subdomain.length < 3) return 'Usa al menos 3 caracteres';
    const reserved = {'www', 'api', 'admin', 'app', 'mail', 'static'};
    if (reserved.contains(subdomain)) return 'Ese subdominio está reservado';
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
