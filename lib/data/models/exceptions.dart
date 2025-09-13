class AppAuthFailure implements Exception {
  final String message;
  AppAuthFailure(this.message);
  @override
  String toString() => message;
}
