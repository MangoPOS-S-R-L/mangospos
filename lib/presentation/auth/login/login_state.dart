class LoginState {
  final bool isLoading;
  final String email;
  final String password;
  final bool rememberMe;
  final String? error;

  const LoginState({
    this.isLoading = false,
    this.email = '',
    this.password = '',
    this.rememberMe = false,
    this.error,
  });

  LoginState copyWith({
    bool? isLoading,
    String? email,
    String? password,
    bool? rememberMe,
    String? error,
  }) {
    return LoginState(
      isLoading: isLoading ?? this.isLoading,
      email: email ?? this.email,
      password: password ?? this.password,
      rememberMe: rememberMe ?? this.rememberMe,
      error: error,
    );
  }
}
