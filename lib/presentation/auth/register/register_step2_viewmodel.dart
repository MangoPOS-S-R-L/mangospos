import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/env/supabase_flutter.dart';
import 'package:mangopos/presentation/auth/register/register_step1_viewmodel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'register_step2_state.dart';

class RegisterStep2ViewModel extends Notifier<RegisterStep2State> {
  @override
  RegisterStep2State build() => const RegisterStep2State();

  void setBranch(String v)  => state = state.copyWith(branchName: v);
  void setCountry(String v) => state = state.copyWith(country: v);
  void setAddress(String v) => state = state.copyWith(address: v);

  Future<void> submitAll() async {
    final supabase = SupabaseConfig.client;

    try {
      final step1 = ref.read(registerStep1VmProvider);
      final step2 = state;

      if ((step1.restaurantName ?? '').trim().isEmpty) {
        throw Exception('Falta el nombre del restaurante');
      }
      if ((step1.email ?? '').trim().isEmpty || (step1.password ?? '').isEmpty) {
        throw Exception('Faltan correo o contraseña');
      }
      final domain = (step1.domain ?? '').trim().toLowerCase();
      if (domain.isEmpty || !domain.endsWith('.mangopos.do')) {
        throw Exception('Dominio inválido. Debe terminar en .mangopos.do');
      }

      final exists = await supabase
          .from('businesses')
          .select('id')
          .eq('domain', domain)
          .maybeSingle();
      if (exists != null) throw Exception('El dominio "$domain" ya está en uso.');

      final AuthResponse resp = await supabase.auth.signUp(
        email: step1.email!,
        password: step1.password!,
      );

      if (supabase.auth.currentSession == null) {
        await supabase.auth.signInWithPassword(
          email: step1.email!,
          password: step1.password!,
        );
      }

      final user = resp.user ?? supabase.auth.currentUser;
      if (user == null) throw Exception('No se pudo obtener el usuario.');
      final userId = user.id;

      await supabase.from('profiles').insert({
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
            'business_name': step1.restaurantName,
            'branch_name': step2.branchName,
            'country': step2.country,
            'address': step2.address,
            'domain': domain,
            'status': 'active',
            'created_at': DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          })
          .select('id')
          .single();

      final businessId = business['id'] as String;

      await supabase.from('memberships').insert({
        'user_id': userId,
        'business_id': businessId,
        'plan_type': 'trial',
        'status': 'active',
        'start_date': DateTime.now().toIso8601String(),
        'end_date': DateTime.now().add(const Duration(days: 30)).toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
      });

      await supabase.from('user_businesses').insert({
        'user_id': userId,
        'business_id': businessId,
        'role': 'owner',
        'permissions': ['all'],
        'created_at': DateTime.now().toIso8601String(),
      });

    } on PostgrestException catch (e) {
      throw Exception('No se pudo completar el registro: ${e.message}');
    }
  }
}

final registerStep2VmProvider =
    NotifierProvider<RegisterStep2ViewModel, RegisterStep2State>(
  RegisterStep2ViewModel.new,
);
