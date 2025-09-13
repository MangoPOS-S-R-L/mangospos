import 'package:mangopos/data/datasources/remote/auth_remote_ds.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/models/exceptions.dart';

import '../../../domain/repositories/auth_repository.dart';

class AuthRepositoryImpl implements AuthRepository {
  final AuthRemoteDS remote;
  AuthRepositoryImpl(this.remote);

  @override
  Future<String> signIn(String email, String password) async {
    try {
      final r = await remote.signIn(email, password);
      final user = r.user ?? Supabase.instance.client.auth.currentUser;
      if (user == null) throw AuthException('No se pudo iniciar sesión');
      return user.id;
    } on AuthException catch (e) {
      throw AppAuthFailure(e.message);
    } catch (_) {
      throw AppAuthFailure('Error de autenticación');
    }
  }

  @override
  Future<String> signUp(String email, String password) async {
    try {
      final r = await remote.signUp(email, password);
      final user = r.user ?? Supabase.instance.client.auth.currentUser;
      if (user == null) throw AuthException('No se pudo registrar');
      return user.id;
    } on AuthException catch (e) {
      throw AppAuthFailure(e.message);
    } catch (_) {
      throw AppAuthFailure('Error registrando usuario');
    }
  }

  @override
  Future<void> signOut() => remote.signOut();

  @override
  String? currentUserId() => remote.currentUser?.id;

  @override
  Future<void> createProfile({required String userId, required String fullName}) {
    return remote.createProfile(userId: userId, fullName: fullName);
  }
}
