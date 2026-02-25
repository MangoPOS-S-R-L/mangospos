class LoginState {
  final bool isLoading;
  final String email;
  final String password;
  final String? error;

  const LoginState({
    this.isLoading = false,
    this.email = '',
    this.password = '',
    this.error,
  });

  LoginState copyWith({
    bool? isLoading,
    String? email,
    String? password,
    String? error,
  }) {
    return LoginState(
      isLoading: isLoading ?? this.isLoading,
      email: email ?? this.email,
      password: password ?? this.password,
      error: error,
    );
  }
}
