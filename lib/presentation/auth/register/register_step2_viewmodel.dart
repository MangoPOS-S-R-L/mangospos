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
        throw Exception('Faltan correo o contraseña');
      }
      if (step2.businessName.trim().isEmpty) {
        throw Exception('Falta el nombre del negocio');
      }
      // Multi-tenant web removido: el sistema corre centralizado en app.mangopos.do.
      final domain = 'app.mangopos.do';

      final AuthResponse resp = await supabase.auth.signUp(
        email: step1.email!,
        password: step1.password!,
      );
      final session = resp.session ?? supabase.auth.currentSession;
      final user = resp.user ?? session?.user ?? supabase.auth.currentUser;
      if (user == null) {
        throw Exception('No se pudo crear el usuario o la sesión.');
      }
      final userId = user.id;

      await supabase.from('profiles').upsert({
        'id': userId,
        'email': step1.email,
        'full_name': step1.fullName,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      final business = await supabase
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
            'phone': step2.phone.trim().isEmpty ? null : step2.phone.trim(),
            'domain': domain,
            'status': 'active',
            'created_at': DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          })
          .select('id')
          .single();

      final businessId = business['id'] as String;
      final normalizedPlan = _resolveMembershipPlan(step1.selectedPlan);
      final now = DateTime.now();

      await supabase.from('memberships').insert({
        'user_id': userId,
        'business_id': businessId,
        'plan_type': normalizedPlan,
        'status': 'active',
        'start_date': now.toIso8601String(),
        'end_date': now.add(const Duration(days: 14)).toIso8601String(),
        'created_at': now.toIso8601String(),
      });

      if (session != null) {
        await ref.read(sessionProvider.notifier).restoreFromSupabaseSession();
        return const RegisterSubmitResult(
          requiresEmailConfirmation: false,
          message:
              'Todo quedó creado correctamente. En unos segundos entrarás al panel principal.',
        );
      }

      return const RegisterSubmitResult(
        requiresEmailConfirmation: true,
        message:
            'Cuenta creada correctamente. Revisa tu correo para confirmar tu cuenta y luego inicia sesión.',
      );
    } on PostgrestException catch (e) {
      throw Exception('No se pudo completar el registro: ${e.message}');
    } on AuthException catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('security purposes') ||
          msg.contains('after') && msg.contains('seconds')) {
        throw Exception(
          'Supabase limitó temporalmente la creación de la cuenta. Espera unos segundos y vuelve a intentarlo una sola vez.',
        );
      }
      throw Exception(e.message);
    }
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
