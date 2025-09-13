abstract class BusinessRepository {
  Future<String> createBusiness({
    required String name,
    required String email,
    required String address,
    String? country,
  });
  Future<void> addMembership({
    required String userId,
    required String businessId,
    String role,
  });
}
