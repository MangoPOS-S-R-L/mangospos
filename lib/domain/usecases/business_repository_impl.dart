import 'package:mangopos/data/datasources/remote/business_remote_ds.dart';

import '../../../domain/repositories/business_repository.dart';

class BusinessRepositoryImpl implements BusinessRepository {
  final BusinessRemoteDS remote;
  BusinessRepositoryImpl(this.remote);

  @override
  Future<String> createBusiness({
    required String name,
    required String email,
    required String address,
    String? country,
  }) =>
      remote.createBusiness(name: name, email: email, address: address, country: country);

  @override
  Future<void> addMembership({
    required String userId,
    required String businessId,
    String role = 'owner',
  }) => remote.addMembership(userId: userId, businessId: businessId, role: role);
}
