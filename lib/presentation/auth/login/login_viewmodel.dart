import 'dart:async';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../../../services/session/session_controller.dart';
import '../../../core/utils/logger.dart';
import '../../../core/auth/session_bridge.dart';
import '../../../core/tenant/tenant_resolver.dart';
import 'login_state.dart';

class LoginViewModel extends Notifier<LoginState> {
  @override
  LoginState build() => const LoginState();

  void setEmail(String email) {
    _safeSet(state.copyWith(email: email, error: null));
  }

  void setPassword(String password) {
    _safeSet(state.copyWith(password: password, error: null));
  }

  void _safeSet(LoginState next) {
    if (state == next) return;
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) => state = next);
    } else {
      state = next;
    }
  }

  Future<void> submit() async {
    if (state.email.isEmpty || state.password.isEmpty) {
      _safeSet(state.copyWith(error: 'Ingresa correo y contraseña'));
      return;
    }
    _safeSet(state.copyWith(isLoading: true, error: null));

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
        _safeSet(state.copyWith(
          isLoading: false,
          error: 'Credenciales inválidas o usuario no encontrado',
        ));
        return;
      }

      // Obtener perfile
      final profileResp = await supabase
          .from('profiles')
          .select('full_name')
          .eq('id', user.id)
          .maybeSingle();
      final fullName = profileResp?['full_name'] as String? ?? 'Usuario';

      // Obtener todos los roles y negocios asignados en lugar de solo uno (Soporta multi-sucursal)
      final userBizResp = await supabase
          .from('user_businesses')
          .select('business_id, role, businesses(business_name, domain)')
          .eq('user_id', user.id);

      final businessesList = userBizResp as List<dynamic>;

      if (businessesList.isEmpty) {
        AppLogger.w('Usuario sin perfil de negocio asignado (user_businesses está vacía)');
        await supabase.auth.signOut();
        _safeSet(state.copyWith(
          isLoading: false,
          error: 'Tu usuario no tiene negocio/rol asignado. Contacta al administrador.',
        ));
        return;
      }

      // Si tiene más de un negocio → mostrar selector
      if (businessesList.length > 1) {
        AppLogger.i('Multi-tenant detectado (${businessesList.length} negocios). Notificando para navegación a selector...');
        _safeSet(state.copyWith(
          isLoading: false,
          needsBusinessSelection: true,
        ));
        return;
      }

      // El usuario solo tiene 1 negocio asignado
      final singleBiz = businessesList.first;
      final businessId = singleBiz['business_id'] as String?;
      final roleStr = singleBiz['role']?.toString();
      final posRole = _mapRole(roleStr);

      if (businessId == null || businessId.isEmpty || posRole == null) {
        AppLogger.e('Atributos críticos faltantes en Login -> businessId: $businessId');
        await supabase.auth.signOut();
        _safeSet(state.copyWith(
          isLoading: false,
          error: 'Tu acceso no está configurado correctamente.',
        ));
        return;
      }

      // Lógica de redirección a subdominio si estamos en app.mangopos.do
      // — ANTES de setAuthenticated para que GoRouter no intervenga.
      if (kIsWeb && TenantResolver.isAppShell) {
        final businessObj = singleBiz['businesses'];
        final domain = businessObj?['domain'] as String?;

        if (domain != null && domain.isNotEmpty) {
          AppLogger.i('[$businessId] Transfiriendo sesión al tenant: $domain');
          _safeSet(state.copyWith(isLoading: false));
          SessionBridge.redirectToTenant(domain);
          return; // El browser navega al tenant; no seguimos montando nada local.
        }
      }

      // Si NO estamos en app.mangopos.do (ej: desktop, mobile, desarrollo local)
      // autenticamos localmente de forma normal.
      ref.read(sessionProvider.notifier).setAuthenticated(
        user.id,
        businessId: businessId,
        userName: fullName,
        activeRole: posRole,
        availableRoles: [posRole],
      );

      AppLogger.i('[$businessId] Login exitoso para $fullName ($roleStr)');

      _safeSet(const LoginState());
    } on AuthException catch (e, st) {
      AppLogger.w('AuthException durante login', error: e, stackTrace: st);
      _safeSet(state.copyWith(isLoading: false, error: e.message));
    } on TimeoutException catch (e, st) {
      AppLogger.w('Timeout en auth', error: e, stackTrace: st);
      _safeSet(state.copyWith(
        isLoading: false,
        error: 'Tiempo de espera agotado. Revisa tu conexión de red.',
      ));
    } catch (e, st) {
      AppLogger.e('Error no controlado en login', error: e, stackTrace: st);
      _safeSet(state.copyWith(
        isLoading: false,
        error: 'Ocurrió un error inesperado',
      ));
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
