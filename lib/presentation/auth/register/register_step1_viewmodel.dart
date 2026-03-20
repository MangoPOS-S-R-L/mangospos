import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'register_step1_state.dart';

class RegisterStep1ViewModel extends Notifier<RegisterStep1State> {
  static const _allowedPlans = {'trial', 'starter', 'pro', 'enterprise'};

  @override
  RegisterStep1State build() => const RegisterStep1State();

  void setFullName(String v) => _safeSet(state.copyWith(fullName: v));
  void setEmail(String v) => _safeSet(state.copyWith(email: v));
  void setPassword(String v) => _safeSet(state.copyWith(password: v));

  void setSelectedPlan(String? plan) {
    final normalized = plan?.trim().toLowerCase();
    final resolved = _allowedPlans.contains(normalized) ? normalized : 'starter';
    _safeSet(state.copyWith(selectedPlan: resolved));
  }

  void _safeSet(RegisterStep1State next) {
    if (state == next) return;
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) => state = next);
    } else {
      state = next;
    }
  }
}

final registerStep1VmProvider =
    NotifierProvider<RegisterStep1ViewModel, RegisterStep1State>(
      RegisterStep1ViewModel.new,
    );
