// lib/presentation/auth/login/login_viewmodel.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/session/session_controller.dart';
import 'login_state.dart';

class LoginViewModel extends Notifier<LoginState> {
  @override
  LoginState build() => const LoginState();

  void setEmail(String v) {
    state = state.copyWith(email: v, error: null);
  }

  void setPassword(String v) {
    state = state.copyWith(password: v, error: null);
  }

  void toggleRemember(bool v) {
    state = state.copyWith(rememberMe: v, error: null);
  }

  Future<void> submit() async {
    if (state.email.trim().isEmpty || !state.email.contains('@')) {
      state = state.copyWith(error: 'Correo inválido');
      return;
    }
    if (state.password.length < 6) {
      state = state.copyWith(
        error: 'La contraseña debe tener al menos 6 caracteres',
      );
      return;
    }

    state = state.copyWith(isLoading: true, error: null);

    try {
      final supa = Supabase.instance.client;

      final response = await supa.auth.signInWithPassword(
        email: state.email.trim(),
        password: state.password,
      );

      final user = response.user ?? supa.auth.currentUser;
      if (user == null) {
        throw const AuthException(
          'No se pudo iniciar sesión. Inténtalo de nuevo.',
        );
      }

      // Actualiza la sesión global
      ref.read(sessionProvider.notifier).setAuthenticated(user.id);

      state = state.copyWith(isLoading: false, error: null);
    } on AuthException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    } catch (_) {
      state = state.copyWith(
        isLoading: false,
        error: 'Ocurrió un error iniciando sesión',
      );
    }
  }
}

final loginVmProvider = NotifierProvider<LoginViewModel, LoginState>(
  LoginViewModel.new,
);
