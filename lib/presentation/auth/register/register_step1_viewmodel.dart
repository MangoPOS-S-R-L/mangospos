import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/billing_plan.dart';
import 'register_step1_state.dart';

class RegisterStep1ViewModel extends Notifier<RegisterStep1State> {
  // Códigos de plan legacy aceptados en memberships.plan_type (text).
  // Mapeo con la tabla `plans`: code 'basic' → text 'starter' por compat histórica.
  static const _legacyAllowedPlans = {'trial', 'starter', 'pro', 'enterprise'};

  @override
  RegisterStep1State build() => const RegisterStep1State();

  void setFullName(String v) => _safeSet(state.copyWith(fullName: v));
  void setEmail(String v) => _safeSet(state.copyWith(email: v));
  void setPassword(String v) => _safeSet(state.copyWith(password: v));

  /// Legacy: se usa cuando llega por deep-link `?plan=pro`. Solo string.
  void setSelectedPlan(String? plan) {
    final normalized = plan?.trim().toLowerCase();
    final resolved = _legacyAllowedPlans.contains(normalized) ? normalized : 'starter';
    _safeSet(state.copyWith(selectedPlan: resolved));
  }

  /// Setea ambos campos (UUID + legacy code) desde un BillingPlan de la tabla
  /// `plans`. Mapea code → plan_type legacy text para mantener compatibilidad.
  void setSelectedFromBillingPlan(BillingPlan plan) {
    final legacyCode = _mapToLegacy(plan.code);
    _safeSet(state.copyWith(
      selectedPlanId: plan.id,
      selectedPlan: legacyCode,
    ));
  }

  /// Map del code de tabla plans (basic/pro/enterprise) al texto que acepta
  /// `memberships.plan_type` (trial|free|basic|pro segun el CHECK). El check
  /// actual NO incluye 'starter' ni 'enterprise', así que mapeamos:
  ///   basic → 'basic'
  ///   pro → 'pro'
  ///   enterprise → 'pro' (no hay enterprise en CHECK legacy; pro es el más alto)
  static String _mapToLegacy(String code) {
    switch (code) {
      case 'basic':
        return 'basic';
      case 'pro':
        return 'pro';
      case 'enterprise':
        return 'pro';
      default:
        return 'basic';
    }
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
