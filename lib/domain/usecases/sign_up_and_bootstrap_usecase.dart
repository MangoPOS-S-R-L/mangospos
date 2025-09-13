import '../repositories/auth_repository.dart';
import '../repositories/business_repository.dart';

class SignUpAndBootstrapUseCase {
  final AuthRepository auth;
  final BusinessRepository biz;

  SignUpAndBootstrapUseCase(this.auth, this.biz);

  /// Crea usuario + profile + business + membership(owner)
  Future<({String userId, String businessId})> call({
    required String email,
    required String password,
    required String fullName,
    required String restaurantName,
    required String branchAddress,
    String? country,
  }) async {
    final userId = await auth.signUp(email, password);

    // profile
    await auth.createProfile(userId: userId, fullName: fullName);

    // business
    final businessId = await biz.createBusiness(
      name: restaurantName,
      email: email,
      address: branchAddress,
      country: country,
    );

    // membership owner
    await biz.addMembership(userId: userId, businessId: businessId, role: 'owner');

    return (userId: userId, businessId: businessId);
  }
}
