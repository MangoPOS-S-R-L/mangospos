import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'register_step1_state.dart';

class RegisterStep1ViewModel extends Notifier<RegisterStep1State> {
  @override
  RegisterStep1State build() => const RegisterStep1State();

  void setRestaurant(String v) => state = state.copyWith(restaurantName: v);
  void setFullName(String v) => state = state.copyWith(fullName: v);
  void setEmail(String v) => state = state.copyWith(email: v);
  void setPassword(String v) => state = state.copyWith(password: v);
  void setDomain(String v) => state = state.copyWith(domain: v);
}

final registerStep1VmProvider =
    NotifierProvider<RegisterStep1ViewModel, RegisterStep1State>(
      RegisterStep1ViewModel.new,
    );
