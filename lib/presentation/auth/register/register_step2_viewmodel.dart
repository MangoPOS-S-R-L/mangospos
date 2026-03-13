import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/env/supabase_flutter.dart';
import 'package:mangopos/presentation/auth/register/register_step1_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'register_step2_state.dart';

class RegisterStep2ViewModel extends Notifier<RegisterStep2State> {
  @override
  RegisterStep2State build() => const RegisterStep2State();

  void setBusinessName(String v) => state = state.copyWith(businessName: v);
  void setBranch(String v) => state = state.copyWith(branchName: v);
  void setBusinessType(String v) => state = state.copyWith(businessType: v);
  void setCountry(String v) => state = state.copyWith(country: v);
  void setAddress(String v) => state = state.copyWith(address: v);
  void setPhone(String v) => state = state.copyWith(phone: v);
  void setSubdomain(String v) => state = state.copyWith(subdomain: v);

  Future<void> submitAll() async {
    final supabase = SupabaseConfig.client;

    try {
      final step1 = ref.read(registerStep1VmProvider);
      final step2 = state;

      if ((step1.email ?? '').trim().isEmpty || (step1.password ?? '').isEmpty) {
        throw Exception('Faltan correo o contraseña');
      }
      if (step2.businessName.trim().isEmpty) {
        throw Exception('Falta el nombre del negocio');
      }
      final normalizedSubdomain = _normalizeSubdomain(step2.subdomain);
      if (normalizedSubdomain.isEmpty) {
        throw Exception('Subdominio inválido');
      }
      final domain = '$normalizedSubdomain.mangopos.do';

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
      final session = resp.session ?? supabase.auth.currentSession;
      final user = resp.user ?? session?.user ?? supabase.auth.currentUser;
      if (session == null || user == null) {
        throw Exception(
          'La cuenta fue creada pero tu proyecto no devolvió una sesión activa todavía. Espera un momento y luego inicia sesión para terminar de entrar.',
        );
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

      await supabase.from('memberships').insert({
        'user_id': userId,
        'business_id': businessId,
        'plan_type': 'trial',
        'status': 'active',
        'start_date': DateTime.now().toIso8601String(),
        'end_date': DateTime.now().add(const Duration(days: 30)).toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
      });

      await ref.read(sessionProvider.notifier).restoreFromSupabaseSession();
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
    final normalizedSubdomain = _normalizeSubdomain(state.subdomain);
    if (normalizedSubdomain.isEmpty) return 'tunegocio.mangopos.do';
    return '$normalizedSubdomain.mangopos.do';
  }

  String _normalizeSubdomain(String raw) {
    final normalized = raw
        .trim()
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ñ', 'n');
    final base = normalized
        .trim()
        .toLowerCase()
        .replaceAll('.mangopos.do', '')
        .replaceAll(RegExp(r'[^a-z0-9-]'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return base;
  }
}

final registerStep2VmProvider =
    NotifierProvider<RegisterStep2ViewModel, RegisterStep2State>(
  RegisterStep2ViewModel.new,
);
