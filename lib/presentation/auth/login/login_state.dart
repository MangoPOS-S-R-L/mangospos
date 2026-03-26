class LoginState {
  final bool isLoading;
  final String email;
  final String password;
  final String? error;
  final bool needsBusinessSelection;

  const LoginState({
    this.isLoading = false,
    this.email = '',
    this.password = '',
    this.error,
    this.needsBusinessSelection = false,
  });

  LoginState copyWith({
    bool? isLoading,
    String? email,
    String? password,
    String? error,
    bool? needsBusinessSelection,
  }) {
    return LoginState(
      isLoading: isLoading ?? this.isLoading,
      email: email ?? this.email,
      password: password ?? this.password,
      error: error,
      needsBusinessSelection: needsBusinessSelection ?? this.needsBusinessSelection,
    );
  }
}
