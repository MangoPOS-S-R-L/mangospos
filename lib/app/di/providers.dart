import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/data/datasources/remote/auth_remote_ds.dart';
import 'package:mangopos/data/datasources/remote/business_remote_ds.dart';
import 'package:mangopos/domain/usecases/auth_repository_impl.dart';
import 'package:mangopos/domain/usecases/business_repository_impl.dart';
import '../../domain/repositories/auth_repository.dart';
import '../../domain/repositories/business_repository.dart';
import '../../domain/usecases/sign_in_usecase.dart';
import '../../domain/usecases/sign_up_and_bootstrap_usecase.dart';

final _authRemoteProvider = Provider((_) => AuthRemoteDS());
final _bizRemoteProvider  = Provider((_) => BusinessRemoteDS());

final authRepoProvider = Provider<AuthRepository>(
  (ref) => AuthRepositoryImpl(ref.read(_authRemoteProvider)),
);
final businessRepoProvider = Provider<BusinessRepository>(
  (ref) => BusinessRepositoryImpl(ref.read(_bizRemoteProvider)),
);

final signInUseCaseProvider = Provider((ref) => SignInUseCase(ref.read(authRepoProvider)));
final signUpAndBootstrapUseCaseProvider = Provider(
  (ref) => SignUpAndBootstrapUseCase(ref.read(authRepoProvider), ref.read(businessRepoProvider)),
);
