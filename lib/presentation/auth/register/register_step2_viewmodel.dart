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


      // 1. Create auth user
      final AuthResponse resp;
      try {
        resp = await supabase.auth.signUp(
          email: step1.email!,
          password: step1.password!,
          emailRedirectTo: 'https://app.mangopos.do/auth/callback',
        );
      } on AuthException catch (e) {
        throw Exception(_friendlyAuthError(e));
      }

      final session = resp.session ?? supabase.auth.currentSession;
      final user = resp.user ?? session?.user ?? supabase.auth.currentUser;
      if (user == null) {
        throw Exception(
          'No se pudo crear la cuenta. Verifica tu correo y contraseña e intenta de nuevo.',
        );
      }
      final userId = user.id;

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

  String _friendlyAuthError(AuthException e) {
    final msg = e.message.toLowerCase();
    if (msg.contains('already registered') ||
        msg.contains('already been registered') ||
        msg.contains('user_already_exists')) {
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
