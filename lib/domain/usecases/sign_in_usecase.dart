import '../repositories/auth_repository.dart';

class SignInUseCase {
  final AuthRepository repo;
  SignInUseCase(this.repo);
  Future<String> call(String email, String password) => repo.signIn(email, password);
}
