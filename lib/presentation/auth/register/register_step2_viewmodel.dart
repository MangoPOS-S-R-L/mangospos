import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/env/supabase_flutter.dart';
import 'package:mangopos/presentation/auth/register/register_step1_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'register_step2_state.dart';

class RegisterSubmitResult {
  final bool requiresEmailConfirmation;
  final String message;

  const RegisterSubmitResult({
    required this.requiresEmailConfirmation,
    required this.message,
  });
}

class RegisterStep2ViewModel extends Notifier<RegisterStep2State> {
  @override
  RegisterStep2State build() => const RegisterStep2State();

  void setBusinessName(String v) => _safeSet(state.copyWith(businessName: v));
  void setBranch(String v) => _safeSet(state.copyWith(branchName: v));
  void setBusinessType(String v) => _safeSet(state.copyWith(businessType: v));
  void setCountry(String v) => _safeSet(state.copyWith(country: v));
  void setAddress(String v) => _safeSet(state.copyWith(address: v));
  void setPhone(String v) => _safeSet(state.copyWith(phone: v));
  void setSubdomain(String v) => _safeSet(state.copyWith(subdomain: v));

  void _safeSet(RegisterStep2State next) {
    if (state == next) return;
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) => state = next);
    } else {
      state = next;
    }
  }

  Future<RegisterSubmitResult> submitAll() async {
    final supabase = SupabaseConfig.client;

    try {
      final step1 = ref.read(registerStep1VmProvider);
      final step2 = state;

      if ((step1.email ?? '').trim().isEmpty ||
          (step1.password ?? '').isEmpty) {
        throw Exception('Faltan correo o contraseña. Regresa al paso 1.');
      }
      if (step2.businessName.trim().isEmpty) {
        throw Exception('Falta el nombre del negocio. Regresa al paso 2.');
      }


      // 1. Auth: signUp con flujo de recovery para usuarios huérfanos.
      //
      // Bug histórico: si el primer intento creaba auth.users pero
      // fallaba en pasos posteriores (insert de business, etc.), el
      // usuario quedaba huérfano. Reintentar el form lanzaba "ya
      // existe una cuenta" sin opción de continuar el bootstrap.
      //
      // Fix: cuando signUp detecta "user_already_exists", probamos
      // signInWithPassword con el mismo password ingresado. Si funciona
      // y el user NO tiene business asociado, completamos el bootstrap
      // (recovery del huérfano). Si funciona y SÍ tiene business, la
      // cuenta ya está completa → cerrar sesión recién abierta y
      // mandar al login.
      String userId;
      Session? session;

      AuthResponse? signUpResp;
      try {
        signUpResp = await supabase.auth.signUp(
          email: step1.email!,
          password: step1.password!,
          emailRedirectTo: 'https://app.mangopos.do/auth/callback',
        );
      } on AuthException catch (e) {
        if (!_isAlreadyRegisteredError(e)) {
          throw Exception(_friendlyAuthError(e));
        }
        // user_already_exists → intentar recovery
        signUpResp = null;
      }

      if (signUpResp != null) {
        // Path normal: signUp exitoso
        session = signUpResp.session ?? supabase.auth.currentSession;
        final user =
            signUpResp.user ?? session?.user ?? supabase.auth.currentUser;
        if (user == null) {
          throw Exception(
            'No se pudo crear la cuenta. Verifica tu correo y contraseña e intenta de nuevo.',
          );
        }
        userId = user.id;
      } else {
        // Path recovery: usuario ya existe, probar signIn
        final AuthResponse signInResp;
        try {
          signInResp = await supabase.auth.signInWithPassword(
            email: step1.email!,
            password: step1.password!,
          );
        } on AuthException {
          // El password no matchea con la cuenta existente.
          throw Exception(
            'Ese correo ya tiene una cuenta y la contraseña no coincide. '
            'Inicia sesión desde la pantalla principal o usa "¿Olvidaste tu contraseña?".',
          );
        }
        session = signInResp.session;
        final user = signInResp.user ?? session?.user;
        if (user == null) {
          throw Exception(
            'No se pudo recuperar la cuenta. Intenta iniciar sesión desde la pantalla principal.',
          );
        }
        userId = user.id;

        // Validar si la cuenta ya está completa (tiene business).
        // Si sí → no estamos recuperando un huérfano, el usuario
        // simplemente está intentando registrarse con un email que ya
        // tiene cuenta activa.
        try {
          final existingBiz = await supabase
              .from('businesses')
              .select('id')
              .eq('owner_id', userId)
              .limit(1)
              .maybeSingle();
          if (existingBiz != null) {
            // Cerrar la sesión que acabamos de abrir — no es nuestro flow.
            await supabase.auth.signOut();
            throw Exception(
              'Esta cuenta ya está registrada y activa. '
              'Inicia sesión desde la pantalla principal en lugar de crear una nueva.',
            );
          }
        } on PostgrestException catch (e) {
          throw Exception(
            'No se pudo verificar el estado de la cuenta: ${_friendlyDbError(e)}',
          );
        }
        // Si no había business, caemos al bootstrap normal abajo
        // (profile upsert + business insert + membership insert).
      }

      // 2. Create profile
      try {
        await supabase.from('profiles').upsert({
          'id': userId,
          'email': step1.email,
          'full_name': step1.fullName,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });
      } on PostgrestException catch (e) {
        throw Exception('Error creando tu perfil: ${_friendlyDbError(e)}');
      }

      // 3. Create business
      final Map<String, dynamic> business;
      
      // Clean and ensure unique domain/slug
      var slug = step2.subdomain.trim().toLowerCase();
      if (slug.isEmpty) {
        slug = step2.businessName
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]'), '-')
            .replaceAll(RegExp(r'-+'), '-')
            .trim();
        if (slug.endsWith('-')) slug = slug.substring(0, slug.length - 1);
        
        // Add a small random suffix if slug is very common or to be safer
        final random = DateTime.now().millisecondsSinceEpoch.toString().substring(10);
        slug = '$slug-$random';
      }
      
      final finalDomain = '$slug.mangopos.do';

      try {
        business = await supabase
            .from('businesses')
            .insert({
              'owner_id': userId,
              'business_name': step2.businessName,
              'branch_name': step2.branchName.trim().isEmpty
                  ? 'Sucursal Principal'
                  : step2.branchName.trim(),
              'business_type': step2.businessType,
              'country': step2.country,
              'address': step2.address,
              'phone':
                  step2.phone.trim().isEmpty ? null : step2.phone.trim(),
              'domain': finalDomain,
              'status': 'active',
              'created_at': DateTime.now().toIso8601String(),
              'updated_at': DateTime.now().toIso8601String(),
            })
            .select('id')
            .single();
      } on PostgrestException catch (e) {
        throw Exception(
            'Error creando el negocio: ${_friendlyDbError(e)}');
      }

      // 4. Create membership
      final businessId = business['id'] as String;
      final normalizedPlan = _resolveMembershipPlan(step1.selectedPlan);
      final now = DateTime.now();

      try {
        await supabase.from('memberships').insert({
          'user_id': userId,
          'business_id': businessId,
          'plan_type': normalizedPlan,
          'status': 'active',
          'start_date': now.toIso8601String(),
          'end_date': now.add(const Duration(days: 14)).toIso8601String(),
          'created_at': now.toIso8601String(),
        });
      } on PostgrestException catch (e) {
        throw Exception(
            'Error activando la membresía: ${_friendlyDbError(e)}');
      }

      // 5. Restore session and redirect
      if (session != null) {
        await ref.read(sessionProvider.notifier).restoreFromSupabaseSession();
        return const RegisterSubmitResult(
          requiresEmailConfirmation: false,
          message:
              'Cuenta creada exitosamente. En unos segundos entrarás al panel principal.',
        );
      }

      return const RegisterSubmitResult(
        requiresEmailConfirmation: true,
        message:
            'Cuenta creada exitosamente. Revisa tu correo para confirmar tu cuenta y luego inicia sesión.',
      );
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception(
        'Ocurrió un error inesperado. Verifica tu conexión a internet e intenta de nuevo.',
      );
    }
  }

  /// `true` si el AuthException representa "user_already_exists" en
  /// cualquiera de las variantes que devuelve Supabase Auth (mensajes han
  /// cambiado entre versiones — cubrimos las 3 conocidas).
  bool _isAlreadyRegisteredError(AuthException e) {
    final msg = e.message.toLowerCase();
    return msg.contains('already registered') ||
        msg.contains('already been registered') ||
        msg.contains('user_already_exists');
  }

  String _friendlyAuthError(AuthException e) {
    final msg = e.message.toLowerCase();
    if (_isAlreadyRegisteredError(e)) {
      return 'Ya existe una cuenta con este correo electrónico. Intenta iniciar sesión o usa otro correo.';
    }
    if (msg.contains('invalid') && msg.contains('email')) {
      return 'El formato del correo electrónico no es válido.';
    }
    if (msg.contains('weak') || msg.contains('password')) {
      return 'La contraseña es muy débil. Usa al menos 8 caracteres con una mayúscula y un número.';
    }
    if (msg.contains('security purposes') ||
        (msg.contains('after') && msg.contains('seconds'))) {
      return 'Demasiados intentos. Espera unos segundos antes de intentar de nuevo.';
    }
    if (msg.contains('network') ||
        msg.contains('socket') ||
        msg.contains('timeout')) {
      return 'Error de conexión. Verifica tu internet e intenta de nuevo.';
    }
    return 'Error de autenticación: ${e.message}';
  }

  String _friendlyDbError(PostgrestException e) {
    final msg = e.message.toLowerCase();
    final code = e.code;
    if (code == '23505') {
      if (msg.contains('email')) {
        return 'Ya existe una cuenta con este correo.';
      }
      if (msg.contains('business_name') || msg.contains('domain')) {
        return 'Ya existe un negocio con ese nombre.';
      }
      return 'Ya existe un registro con estos datos.';
    }
    if (code == '23503') {
      return 'Referencia inválida. Intenta de nuevo.';
    }
    if (code == '42501') {
      return 'No tienes permisos para esta operación.';
    }
    if (msg.contains('timeout') || msg.contains('57014')) {
      return 'La operación tardó demasiado. Intenta de nuevo.';
    }
    return e.message;
  }

  String buildDomainPreview() {
    return 'app.mangopos.do';
  }

  String _resolveMembershipPlan(String? rawPlan) {
    const allowedPlans = {'starter', 'pro', 'enterprise', 'trial'};
    final normalized = rawPlan?.trim().toLowerCase();
    if (normalized != null && allowedPlans.contains(normalized)) {
      return normalized;
    }
    return 'starter';
  }
}

final registerStep2VmProvider =
    NotifierProvider<RegisterStep2ViewModel, RegisterStep2State>(
      RegisterStep2ViewModel.new,
    );
