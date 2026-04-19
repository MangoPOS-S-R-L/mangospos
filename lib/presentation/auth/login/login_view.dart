// lib/presentation/auth/login/login_view.dart
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/core/utils/web_utils/web_utils.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'login_state.dart';
import 'login_viewmodel.dart';

const _orange = Color(0xFFF97316);
const _white = Color(0xFFFFFFFF);
const _dark = Color(0xFF32363F);

class LoginView extends ConsumerStatefulWidget {
  const LoginView({super.key});

  @override
  ConsumerState<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends ConsumerState<LoginView> {
  @override
  Widget build(BuildContext context) {
    ref.listen<LoginState>(loginVmProvider, (prev, next) {
      if (next.needsBusinessSelection && context.mounted) {
        context.go(AppRoutes.selectBusiness);
      }
    });

    ref.listen<SessionState>(sessionProvider, (prev, next) {
      if (next.status == AuthStatus.authenticated && context.mounted) {
        final home = ref.read(sessionProvider.notifier).homeRoute;
        context.go(home);
      }
    });

    ref.listen(loginVmProvider, (prev, next) {
      if (prev?.isLoading == true &&
          next.isLoading == false &&
          next.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.error!),
            backgroundColor: Colors.redAccent,
            action: SnackBarAction(
              label: 'OK',
              textColor: Colors.white,
              onPressed: () {},
            ),
          ),
        );
      }
    });

    final state = ref.watch(loginVmProvider);
    final vm = ref.read(loginVmProvider.notifier);
    final isLoading = state.isLoading;
    final isWide = MediaQuery.of(context).size.width >= 980;

    final formCard = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Card(
          color: _white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: _dark.withValues(alpha: .08)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Image.asset(
                  'assets/images/Logo Completo.png',
                  height: 80,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 20),

                _label('Correo electrónico'),
                const SizedBox(height: 8),
                TextField(
                  keyboardType: TextInputType.emailAddress,
                  enabled: !isLoading && !state.needsEmailConfirmation,
                  onChanged: vm.setEmail,
                  decoration: _inputDecoration('tucorreo@ejemplo.com'),
                  style: const TextStyle(
                    color: _dark,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),

                if (state.needsEmailConfirmation) ...[
                  _label('Código de verificación (6 dígitos)'),
                  const SizedBox(height: 8),
                  TextField(
                    keyboardType: TextInputType.number,
                    enabled: !isLoading,
                    onChanged: vm.setConfirmationCode,
                    maxLength: 6,
                    decoration: _inputDecoration('000000').copyWith(counterText: ''),
                    style: const TextStyle(
                      color: _dark,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 8,
                    ),
                  ),
                  const SizedBox(height: 24),
                ] else ...[
                  _label('Contraseña'),
                  const SizedBox(height: 8),
                  _PasswordField(
                    initial: state.password,
                    enabled: !isLoading,
                    onChanged: vm.setPassword,
                  ),
                  const SizedBox(height: 24),
                ],

                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _orange,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    onPressed: isLoading
                        ? null
                        : (state.needsEmailConfirmation ? vm.verifyOTP : vm.submit),
                    child: isLoading
                        ? const CircularProgressIndicator.adaptive(
                            valueColor: AlwaysStoppedAnimation<Color>(_white),
                          )
                        : Text(
                            state.needsEmailConfirmation
                                ? 'Verificar y Entrar'
                                : 'Iniciar sesión',
                            style: const TextStyle(
                              color: _white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),

                const SizedBox(height: 12),
                TextButton(
                  onPressed: isLoading
                      ? null
                      : () => context.go(AppRoutes.register),
                  style: TextButton.styleFrom(
                    foregroundColor: _orange,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text(
                    '¿No tienes cuenta? Registra tu negocio',
                    style: TextStyle(fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center,
                  ),
                ),

                if (state.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    state.error!,
                    style: const TextStyle(color: Colors.redAccent),
                    textAlign: TextAlign.center,
                  ),
                ],

                const SizedBox(height: 8),
                Text(
                  'Ingresa desde app.mangopos.do y luego podras conectar la redirección al subdominio de cada negocio.',
                  style: TextStyle(
                    color: _dark.withValues(alpha: .65),
                    fontSize: 11,
                  ),
                  textAlign: TextAlign.center,
                ),

              ],
            ),
          ),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: _white,
      body: SafeArea(
        child: isWide
            ? Row(
                children: [
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: ClipRRect(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                        child: _LoginImagePane(),
                      ),
                    ),
                  ),
                  Expanded(child: Center(child: formCard)),
                ],
              )
            : Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const ClipRRect(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                        child: _LoginImagePane(height: 220),
                      ),
                      const SizedBox(height: 16),
                      formCard,
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _label(String text) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      style: const TextStyle(
        color: _dark,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: _dark.withValues(alpha: .45)),
    filled: true,
    fillColor: _white,
    focusedBorder: _border(_orange),
    enabledBorder: _border(_dark.withValues(alpha: .25)),
    errorBorder: _border(Colors.redAccent),
    focusedErrorBorder: _border(Colors.redAccent),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
  );

  OutlineInputBorder _border(Color c) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: c, width: 1),
  );
}

class _LoginImagePane extends StatelessWidget {
  static const _images = [
    'assets/Login Images/pexels-japy-29142659.jpg',
    'assets/Login Images/pexels-maxwell-de-sousa-2044217811-29161604.jpg',
  ];

  // Pick a random image once per app session (stable across rebuilds).
  static final int _selectedIndex = Random().nextInt(_images.length);

  final double? height;
  const _LoginImagePane({this.height});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Image.asset(
        _images[_selectedIndex],
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: _orange.withValues(alpha: 0.08),
          child: const Center(
            child: Icon(Icons.storefront_rounded, size: 64, color: _orange),
          ),
        ),
      ),
    );
  }
}

class _PasswordField extends StatefulWidget {
  final String initial;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const _PasswordField({
    required this.initial,
    required this.enabled,
    required this.onChanged,
  });

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: widget.initial,
      enabled: widget.enabled,
      style: const TextStyle(color: _dark),
      obscureText: _obscure,
      onChanged: widget.onChanged,
      validator: (v) =>
          (v == null || v.length < 6) ? 'Minimo 6 caracteres' : null,
      decoration: InputDecoration(
        hintText: '********',
        hintStyle: TextStyle(color: _dark.withValues(alpha: .45)),
        filled: true,
        fillColor: _white,
        focusedBorder: _b(_orange),
        enabledBorder: _b(_dark.withValues(alpha: .25)),
        errorBorder: _b(Colors.redAccent),
        focusedErrorBorder: _b(Colors.redAccent),
        suffixIcon: IconButton(
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(
            _obscure ? Icons.visibility_off : Icons.visibility,
            color: _dark.withValues(alpha: .7),
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
    );
  }

  OutlineInputBorder _b(Color c) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: c, width: 1),
  );
}
