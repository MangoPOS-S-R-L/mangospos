import 'package:flutter/foundation.dart';

@immutable
class RegisterStep1State {
  final String? fullName;
  final String? email;
  final String? password;
  final String? selectedPlan;

  const RegisterStep1State({
    this.fullName,
    this.email,
    this.password,
    this.selectedPlan,
  });

  RegisterStep1State copyWith({
    String? fullName,
    String? email,
    String? password,
    String? selectedPlan,
  }) {
    return RegisterStep1State(
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      password: password ?? this.password,
      selectedPlan: selectedPlan ?? this.selectedPlan,
    );
  }
}
