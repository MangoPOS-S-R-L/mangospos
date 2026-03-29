import 'package:supabase_flutter/supabase_flutter.dart';

class AuthRemoteDS {
  SupabaseClient get _sb => Supabase.instance.client;

  Future<AuthResponse> signIn(String email, String password) {
    return _sb.auth.signInWithPassword(email: email, password: password);
  }

  Future<AuthResponse> signUp(String email, String password) {
    return _sb.auth.signUp(email: email, password: password);
  }

  Future<void> signOut() => _sb.auth.signOut();

  User? get currentUser => _sb.auth.currentUser;

  Future<void> createProfile({
    required String userId,
    required String fullName,
    String? phone,
  }) async {
    await _sb.from('profiles').upsert({
      'id': userId,
      'full_name': fullName,
      'phone': phone,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }
}
