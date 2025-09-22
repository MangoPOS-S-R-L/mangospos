import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'register_step1_viewmodel.dart';

class RegisterStep1View extends ConsumerStatefulWidget {
  const RegisterStep1View({super.key});

  // Paleta oficial MangoPOS
  static const kPrimaryOrange = Color(0xFFF7941A);
  static const kSuccessGreen = Color(0xFF32AD40);
  static const kWhite = Color(0xFFFFFFFF);
  static const kDarkGray = Color(0xFF32363F);

  @override
  ConsumerState<RegisterStep1View> createState() => _RegisterStep1ViewState();
}

class _RegisterStep1ViewState extends ConsumerState<RegisterStep1View> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _restaurantCtl;
  late final TextEditingController _fullNameCtl;
  late final TextEditingController _emailCtl;
  late final TextEditingController _passwordCtl;
  late final TextEditingController _domainCtl;

  // Control del auto-fill del dominio
  bool _domainTouched = false; // el usuario editó manualmente
  bool __updatingDomainProgrammatically = false; // estamos seteando por código

  @override
  void initState() {
    super.initState();
    final s = ref.read(registerStep1VmProvider);

    _restaurantCtl = TextEditingController(text: s.restaurantName);
    _fullNameCtl = TextEditingController(text: s.fullName);
    _emailCtl = TextEditingController(text: s.email);
    _passwordCtl = TextEditingController(text: s.password);

    // Sugerencia inicial de dominio (si no viene guardado)
    final suggested = s.domain?.trim().isNotEmpty == true
        ? s.domain!.trim()
        : _buildFullDomain(_slugify(s.restaurantName ?? ''));

    _domainCtl = TextEditingController(text: suggested);

    // Si el usuario escribe el nombre, sugerimos dominio (solo si él no lo cambió)
    _restaurantCtl.addListener(() {
      if (_domainTouched) return;
      final slug = _slugify(_restaurantCtl.text);
      _setDomainProgrammatically(_buildFullDomain(slug));
    });

    // Si el usuario edita el dominio, marcamos touched (solo cambios de usuario)
    _domainCtl.addListener(() {
      if (__updatingDomainProgrammatically) return;
      _domainTouched = true;
    });
  }

  @override
  void dispose() {
    _restaurantCtl.dispose();
    _fullNameCtl.dispose();
    _emailCtl.dispose();
    _passwordCtl.dispose();
    _domainCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.read(registerStep1VmProvider.notifier);

    return Scaffold(
      backgroundColor: RegisterStep1View.kWhite,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Card(
              color: RegisterStep1View.kWhite,
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
                        'Crea tu cuenta de Mango POS',
                        style: TextStyle(
                          color: RegisterStep1View.kDarkGray,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 18),

                      // ===== Restaurante =====
                      _label('Nombre del restaurante'),
                      _field(
                        controller: _restaurantCtl,
                        validator: _req,
                        textInputAction: TextInputAction.next,
                        key: const ValueKey('restaurant'),
                      ),
                      const SizedBox(height: 14),

                      // ===== Dominio =====
                      _label('Dominio (ej. restaurant.mangopos.do)'),
                      _field(
                        controller: _domainCtl,
                        validator: (v) {
                          final value = (v ?? '').trim().toLowerCase();
                          if (value.isEmpty) return 'Requerido';
                          if (!value.endsWith('.mangopos.do')) {
                            return 'Debe terminar en .mangopos.do';
                          }
                          final reg = RegExp(r'^[a-z0-9-]+\.mangopos\.do$');
                          if (!reg.hasMatch(value)) {
                            return 'Usa solo letras, números y guiones (ej. mi-tienda.mangopos.do)';
                          }
                          const reserved = {
                            'www',
                            'api',
                            'admin',
                            'app',
                            'mail',
                            'static',
                          };
                          final sub = value.replaceAll('.mangopos.do', '');
                          if (reserved.contains(sub)) {
                            return 'Ese subdominio está reservado';
                          }
                          return null;
                        },
                        textInputAction: TextInputAction.next,
                        key: const ValueKey('domain'),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Consejo: mantenlo corto, sin espacios ni tildes. Se sugerirá a partir del nombre.',
                        style: TextStyle(
                          color: RegisterStep1View.kDarkGray.withOpacity(0.65),
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 14),

                      _label('Tu nombre completo'),
                      _field(
                        controller: _fullNameCtl,
                        validator: _req,
                        textInputAction: TextInputAction.next,
                        key: const ValueKey('fullname'),
                      ),
                      const SizedBox(height: 14),

                      _label('Introduce tu correo electrónico'),
                      _field(
                        controller: _emailCtl,
                        validator: (v) => (v == null || !v.contains('@'))
                            ? 'Correo inválido'
                            : null,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        key: const ValueKey('email'),
                      ),
                      const SizedBox(height: 14),

                      _label('Contraseña'),
                      _field(
                        controller: _passwordCtl,
                        validator: (v) => (v == null || v.length < 6)
                            ? 'Mínimo 6 caracteres'
                            : null,
                        obscure: true,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.newPassword],
                        key: const ValueKey('password'),
                      ),
                      const SizedBox(height: 10),

                      Row(
                        children: [
                          TextButton(
                            onPressed: () => context.go('/login'),
                            style: TextButton.styleFrom(
                              foregroundColor: RegisterStep1View.kDarkGray,
                            ),
                            child: const Text(
                              '¿Ya estás registrado? Inicia sesión aquí',
                            ),
                          ),
                          const Spacer(),
                        ],
                      ),
                      const SizedBox(height: 8),

                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: RegisterStep1View.kPrimaryOrange,
                            foregroundColor: RegisterStep1View.kWhite,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () {
                            if (!(_formKey.currentState?.validate() ?? false)) {
                              return;
                            }

                            // Normalizamos dominio
                            String dom = _domainCtl.text.trim().toLowerCase();
                            if (!dom.endsWith('.mangopos.do')) {
                              final sub = dom.replaceAll(
                                RegExp(r'\.mangopos\.do$'),
                                '',
                              );
                              dom = '${_slugify(sub)}.mangopos.do';
                              _setDomainProgrammatically(
                                dom,
                              ); // refleja en UI sin marcar touched
                            }

                            // Sincroniza al ViewModel una sola vez
                            final vm = ref.read(
                              registerStep1VmProvider.notifier,
                            );
                            vm.setRestaurant(_restaurantCtl.text.trim());
                            vm.setFullName(_fullNameCtl.text.trim());
                            vm.setEmail(_emailCtl.text.trim());
                            vm.setPassword(_passwordCtl.text);
                            vm.setDomain(dom);

                            context.go('/register/branch');
                          },
                          child: const Text(
                            'Siguiente: detalles de la sucursal',
                            style: TextStyle(fontWeight: FontWeight.w600),
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
      ),
    );
  }

  // ===== Helpers de UI =====

  static String? _req(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Requerido' : null;

  Widget _label(String s) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      s,
      style: const TextStyle(
        color: RegisterStep1View.kDarkGray,
        fontSize: 13.5,
      ),
    ),
  );

  Widget _field({
    required TextEditingController controller,
    String? Function(String?)? validator,
    bool obscure = false,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    List<String>? autofillHints,
    Key? key,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      validator: validator,
      obscureText: obscure,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      style: const TextStyle(color: RegisterStep1View.kDarkGray, fontSize: 15),
      decoration: InputDecoration(
        filled: true,
        fillColor: RegisterStep1View.kWhite,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        enabledBorder: _b(RegisterStep1View.kDarkGray.withOpacity(0.20)),
        focusedBorder: _b(RegisterStep1View.kPrimaryOrange),
        errorBorder: _b(Colors.redAccent),
        focusedErrorBorder: _b(Colors.redAccent),
        hintStyle: TextStyle(
          color: RegisterStep1View.kDarkGray.withOpacity(0.45),
        ),
      ),
    );
  }

  OutlineInputBorder _b(Color c) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: c, width: 1.4),
  );

  // ===== Utilidades de dominio =====

  void _setDomainProgrammatically(String value) {
    __updatingDomainProgrammatically = true;
    _domainCtl.text = value;
    __updatingDomainProgrammatically = false;
  }

  String _buildFullDomain(String sub) {
    final s = sub.isEmpty ? '' : sub;
    return '$s.mangopos.do';
  }

  String _slugify(String input) {
    var s = input.toLowerCase().trim();

    // Reemplaza acentos comunes
    const withAccents = 'áàäâãąčćéèëêíìïîñóòöôõúùüûýÿž';
    const withoutAccents = 'aaaaaacceeeeiiiinooooouuuuyyz';
    for (int i = 0; i < withAccents.length; i++) {
      s = s.replaceAll(withAccents[i], withoutAccents[i]);
    }

    // Reemplaza espacios por guión
    s = s.replaceAll(RegExp(r'\s+'), '-');

    // Mantén solo [a-z0-9-]
    s = s.replaceAll(RegExp(r'[^a-z0-9-]'), '');

    // Colapsa guiones múltiples
    s = s.replaceAll(RegExp(r'-{2,}'), '-');

    // Sin guiones al inicio/fin
    s = s.replaceAll(RegExp(r'^-+|-+$'), '');

    return s;
  }
}
