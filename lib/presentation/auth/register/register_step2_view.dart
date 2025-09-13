import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'register_step2_viewmodel.dart';

class RegisterStep2View extends ConsumerStatefulWidget {
  const RegisterStep2View({super.key});

  // Paleta oficial MangoPOS
  static const kPrimaryOrange = Color(0xFFF7941A);
  static const kSuccessGreen = Color(0xFF32AD40);
  static const kWhite = Color(0xFFFFFFFF);
  static const kDarkGray = Color(0xFF32363F);

  @override
  ConsumerState<RegisterStep2View> createState() => _RegisterStep2ViewState();
}

class _RegisterStep2ViewState extends ConsumerState<RegisterStep2View> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _branchCtl;
  late final TextEditingController _addressCtl;
  late String _country;
  bool _submitting = false;

  // Lista en español
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

  // Mapeo EN -> ES
  static const Map<String, String> _enToEs = {
    'Dominican Republic': 'República Dominicana',
    'United States': 'Estados Unidos',
    'Mexico': 'México',
    'Colombia': 'Colombia',
    'Peru': 'Perú',
    'Chile': 'Chile',
    'Argentina': 'Argentina',
    'Spain': 'España',
  };

  String _normalizeCountry(String? raw) {
    if (raw == null || raw.trim().isEmpty) return _countries.first;
    final r = raw.trim();
    if (_countries.contains(r)) return r;
    final mapped = _enToEs[r];
    if (mapped != null && _countries.contains(mapped)) return mapped;
    return _countries.first;
  }

  @override
  void initState() {
    super.initState();
    final s = ref.read(registerStep2VmProvider);
    _branchCtl = TextEditingController(text: s.branchName);
    _addressCtl = TextEditingController(text: s.address);
    _country = _normalizeCountry(s.country);
  }

  @override
  void dispose() {
    _branchCtl.dispose();
    _addressCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.read(registerStep2VmProvider.notifier);

    return Scaffold(
      backgroundColor: RegisterStep2View.kWhite,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Card(
              color: RegisterStep2View.kWhite,
              elevation: 6,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Agregar detalles de la sucursal del restaurante',
                        style: TextStyle(
                          color: RegisterStep2View.kDarkGray,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 18),

                      _label('Nombre de la sucursal'),
                      _field(
                        key: const ValueKey('branchName'),
                        controller: _branchCtl,
                        validator: _req,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 14),

                      _label('País'),
                      DropdownButtonFormField<String>(
                        key: const ValueKey('country'),
                        value: _countries.contains(_country) ? _country : null,
                        decoration: _inputDecoration(),
                        hint: const Text(
                          'Selecciona un país',
                          style: TextStyle(color: RegisterStep2View.kDarkGray),
                        ),
                        items: _countries
                            .map((c) => DropdownMenuItem(
                                  value: c,
                                  child: Text(
                                    c,
                                    style: const TextStyle(
                                      color: RegisterStep2View.kDarkGray,
                                      fontSize: 15,
                                    ),
                                  ),
                                ))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => _country = v);
                        },
                        iconEnabledColor: RegisterStep2View.kDarkGray,
                        dropdownColor: RegisterStep2View.kWhite,
                        style: const TextStyle(
                          color: RegisterStep2View.kDarkGray,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 14),

                      _label('Dirección de la sucursal'),
                      TextFormField(
                        key: const ValueKey('address'),
                        controller: _addressCtl,
                        validator: _req,
                        minLines: 3,
                        maxLines: 5,
                        style: const TextStyle(
                          color: RegisterStep2View.kDarkGray,
                          fontSize: 15,
                        ),
                        decoration: _inputDecoration(),
                      ),
                      const SizedBox(height: 18),

                      Row(
                        children: [
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: RegisterStep2View.kDarkGray.withOpacity(0.30),
                              ),
                              foregroundColor: RegisterStep2View.kDarkGray,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: _submitting ? null : () => context.go('/register'),
                            child: const Text('Atrás'),
                          ),
                          const Spacer(),
                          SizedBox(
                            height: 48,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: RegisterStep2View.kPrimaryOrange,
                                foregroundColor: RegisterStep2View.kWhite,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 18),
                              ),
                              onPressed: _submitting
                                  ? null
                                  : () async {
                                      if (!(_formKey.currentState?.validate() ?? false)) return;

                                      setState(() => _submitting = true);

                                      vm.setBranch(_branchCtl.text.trim());
                                      vm.setCountry(_country);
                                      vm.setAddress(_addressCtl.text.trim());

                                      try {
                                        await vm.submitAll();
                                        if (mounted) context.go('/dashboard');
                                      } catch (e) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('No se pudo completar el registro: $e'),
                                              backgroundColor: Colors.redAccent,
                                            ),
                                          );
                                        }
                                      } finally {
                                        if (mounted) setState(() => _submitting = false);
                                      }
                                    },
                              child: _submitting
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Text(
                                      'Registrarse',
                                      style: TextStyle(fontWeight: FontWeight.w600),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ==== Helpers ====

  static String? _req(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Requerido' : null;

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          s,
          style: TextStyle(
            color: RegisterStep2View.kDarkGray.withOpacity(0.75),
            fontSize: 13.5,
          ),
        ),
      );

  InputDecoration _inputDecoration() {
    return InputDecoration(
      filled: true,
      fillColor: RegisterStep2View.kWhite,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: _b(RegisterStep2View.kDarkGray.withOpacity(0.20)),
      focusedBorder: _b(RegisterStep2View.kPrimaryOrange),
      errorBorder: _b(Colors.redAccent),
      focusedErrorBorder: _b(Colors.redAccent),
      hintStyle: TextStyle(
        color: RegisterStep2View.kDarkGray.withOpacity(0.45),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    String? Function(String?)? validator,
    TextInputAction? textInputAction,
    Key? key,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      validator: validator,
      textInputAction: textInputAction,
      style: const TextStyle(
        color: RegisterStep2View.kDarkGray,
        fontSize: 15,
      ),
      decoration: _inputDecoration(),
    );
  }

  OutlineInputBorder _b(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c, width: 1.4),
      );
}
