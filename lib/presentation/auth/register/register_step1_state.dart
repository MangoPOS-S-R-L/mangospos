import 'package:flutter/foundation.dart';

@immutable
class RegisterStep1State {
  final String? fullName;
  final String? email;
  final String? password;

  const RegisterStep1State({
    this.fullName,
    this.email,
    this.password,
  });

  RegisterStep1State copyWith({
    String? fullName,
    String? email,
    String? password,
  }) {
    return RegisterStep1State(
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      password: password ?? this.password,
    );
  }
}
