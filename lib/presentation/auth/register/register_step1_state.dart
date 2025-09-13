import 'package:flutter/foundation.dart';

@immutable
class RegisterStep1State {
  final String? restaurantName;
  final String? fullName;
  final String? email;
  final String? password;
  final String? domain;

  const RegisterStep1State({
    this.restaurantName,
    this.fullName,
    this.email,
    this.password,
    this.domain,
  });

  RegisterStep1State copyWith({
    String? restaurantName,
    String? fullName,
    String? email,
    String? password,
    String? domain,
  }) {
    return RegisterStep1State(
      restaurantName: restaurantName ?? this.restaurantName,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      password: password ?? this.password,
      domain: domain ?? this.domain,
    );
  }
}
