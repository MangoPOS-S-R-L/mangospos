import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/session/session_controller.dart';
import '../../../core/utils/logger.dart';
import 'login_state.dart';

class LoginViewModel extends Notifier<LoginState> {
  @override
  LoginState build() => const LoginState();

  void setEmail(String email) {
    state = state.copyWith(email: email, error: null);
  }

  void setPassword(String password) {
    state = state.copyWith(password: password, error: null);
  }

  Future<void> submit() async {
    if (state.email.isEmpty || state.password.isEmpty) {
      state = state.copyWith(error: 'Ingresa correo y contraseña');
      return;
    }
    state = state.copyWith(isLoading: true, error: null);

    try {
      final supabase = Supabase.instance.client;
      final response = await supabase.auth.signInWithPassword(
        email: state.email,
        password: state.password,
      );

      final user = response.user;
      if (user == null) {
        AppLogger.w(
          'Login exitoso pero usuario es null en la respuesta de Supabase',
        );
        state = state.copyWith(
          isLoading: false,
          error: 'Credenciales inválidas o usuario no encontrado',
        );
        return;
      }

      // Obtener perfile
      final profileResp = await supabase
          .from('profiles')
          .select('full_name')
          .eq('id', user.id)
          .maybeSingle();
      final fullName = profileResp?['full_name'] as String? ?? 'Usuario';

      // Obtener rol y negocio activo
      final userBizResp = await supabase
          .from('user_businesses')
          .select('business_id, role')
          .eq('user_id', user.id)
          .maybeSingle();

      if (userBizResp == null) {
        AppLogger.w(
          'Usuario sin perfil de negocio asignado (user_businesses está vacía)',
        );
        await supabase.auth.signOut();
        state = state.copyWith(
          isLoading: false,
          error:
              'Tu usuario no tiene negocio/rol asignado. Contacta al administrador.',
        );
        return;
      }

      final businessId = userBizResp['business_id'] as String?;
      final roleStr = userBizResp['role']?.toString();
      final posRole = _mapRole(roleStr);

      if (businessId == null || businessId.isEmpty || posRole == null) {
        AppLogger.e(
          'Atributos críticos faltantes en Login -> businessId: $businessId | Role: $posRole',
        );
        await supabase.auth.signOut();
        state = state.copyWith(
          isLoading: false,
          error:
              'Tu acceso no está configurado correctamente (negocio/rol inválido).',
        );
        return;
      }

      ref
          .read(sessionProvider.notifier)
          .setAuthenticated(
            user.id,
            businessId: businessId,
            userName: fullName,
            activeRole: posRole,
            availableRoles: [posRole],
          );

      AppLogger.i('[$businessId] Login exitoso para $fullName ($roleStr)');
      state = const LoginState();
    } on AuthException catch (e, st) {
      AppLogger.w('AuthException durante login', error: e, stackTrace: st);
      state = state.copyWith(isLoading: false, error: e.message);
    } on TimeoutException catch (e, st) {
      AppLogger.w('Timeout en auth', error: e, stackTrace: st);
      state = state.copyWith(
        isLoading: false,
        error: 'Tiempo de espera agotado. Revisa tu conexión de red.',
      );
    } catch (e, st) {
      AppLogger.e('Error no controlado en login', error: e, stackTrace: st);
      state = state.copyWith(
        isLoading: false,
        error: 'Ocurrió un error inesperado',
      );
    }
  }

  PosRole? _mapRole(String? role) {
    switch (role) {
      case 'owner':
      case 'admin':
        return PosRole.administrador;
      case 'manager':
        return PosRole.supervisor;
      case 'cashier':
        return PosRole.cajero;
      case 'waiter':
        return PosRole.mesero;
      case 'kitchen':
      case 'cook':
      case 'chef':
        return PosRole.cocina;
      case 'delivery':
        return PosRole.delivery;
      default:
        return null;
    }
  }
}

final loginVmProvider = NotifierProvider<LoginViewModel, LoginState>(
  LoginViewModel.new,
);
