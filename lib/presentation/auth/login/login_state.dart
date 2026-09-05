class LoginState {
  final bool isLoading;
  final String email;
  final String password;
  final String? error;
  final bool needsBusinessSelection;
  final bool needsEmailConfirmation;
  final String confirmationCode;

  /// Sube en cada fallo. Permite avisar de nuevo cuando el usuario repite el
  /// mismo error (5 veces la clave mala = 5 avisos, uno reemplazando al otro).
  final int errorTick;

  const LoginState({
    this.isLoading = false,
    this.email = '',
    this.password = '',
    this.error,
    this.needsBusinessSelection = false,
    this.needsEmailConfirmation = false,
    this.confirmationCode = '',
    this.errorTick = 0,
  });

  LoginState copyWith({
    bool? isLoading,
    String? email,
    String? password,
    String? error,
    bool? needsBusinessSelection,
    bool? needsEmailConfirmation,
    String? confirmationCode,
    int? errorTick,
  }) {
    return LoginState(
      isLoading: isLoading ?? this.isLoading,
      email: email ?? this.email,
      password: password ?? this.password,
      error: error,
      needsBusinessSelection:
          needsBusinessSelection ?? this.needsBusinessSelection,
      needsEmailConfirmation:
          needsEmailConfirmation ?? this.needsEmailConfirmation,
      confirmationCode: confirmationCode ?? this.confirmationCode,
      errorTick: errorTick ?? this.errorTick,
    );
  }
}
