import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'register_step1_state.dart';

class RegisterStep1ViewModel extends Notifier<RegisterStep1State> {
  static const _allowedPlans = {'base', 'pro', 'enterprise'};

  @override
  RegisterStep1State build() => const RegisterStep1State();

  void setFullName(String v) => state = state.copyWith(fullName: v);
  void setEmail(String v) => state = state.copyWith(email: v);
  void setPassword(String v) => state = state.copyWith(password: v);

  void setSelectedPlan(String? plan) {
    final normalized = plan?.trim().toLowerCase();
    final resolved = _allowedPlans.contains(normalized) ? normalized : 'base';
    state = state.copyWith(selectedPlan: resolved);
  }
}

final registerStep1VmProvider =
    NotifierProvider<RegisterStep1ViewModel, RegisterStep1State>(
      RegisterStep1ViewModel.new,
    );
