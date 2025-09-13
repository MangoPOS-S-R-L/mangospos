abstract class AuthRepository {
  Future<String> signIn(String email, String password);
  Future<String> signUp(String email, String password);
  Future<void> signOut();
  String? currentUserId();

  // Necesario para el bootstrap de registro
  Future<void> createProfile({required String userId, required String fullName});
}
