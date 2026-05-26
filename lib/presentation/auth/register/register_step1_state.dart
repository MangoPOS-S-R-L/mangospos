import 'package:flutter/foundation.dart';

@immutable
class RegisterStep1State {
  final String? fullName;
  final String? email;
  final String? password;

  /// Legacy: code del plan (basic/pro/enterprise). Mantenido para compatibilidad
  /// con `memberships.plan_type` (text column) hasta que se elimine ese campo.
  final String? selectedPlan;

  /// Nuevo: UUID del plan en `public.plans`. Es la fuente de verdad para
  /// `memberships.plan_id` y para el cobro Azul.
  final String? selectedPlanId;

  const RegisterStep1State({
    this.fullName,
    this.email,
    this.password,
    this.selectedPlan,
    this.selectedPlanId,
  });

  RegisterStep1State copyWith({
    String? fullName,
    String? email,
    String? password,
    String? selectedPlan,
    String? selectedPlanId,
  }) {
    return RegisterStep1State(
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      password: password ?? this.password,
      selectedPlan: selectedPlan ?? this.selectedPlan,
      selectedPlanId: selectedPlanId ?? this.selectedPlanId,
    );
  }
}
