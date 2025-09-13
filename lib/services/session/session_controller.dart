import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AuthStatus { unauthenticated, authenticated, loading }

class SessionState {
  final AuthStatus status;
  final String? userId;
  final String? activeBusinessId;

  const SessionState({
    this.status = AuthStatus.unauthenticated,
    this.userId,
    this.activeBusinessId,
  });

  SessionState copyWith({
    AuthStatus? status,
    String? userId,
    String? activeBusinessId,
  }) {
    return SessionState(
      status: status ?? this.status,
      userId: userId ?? this.userId,
      activeBusinessId: activeBusinessId ?? this.activeBusinessId,
    );
  }
}

/// Riverpod 3.0 → usar Notifier<T>
class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() => const SessionState();

  void setLoading() => state = state.copyWith(status: AuthStatus.loading);

  void setAuthenticated(String userId, {String? businessId}) {
    state = SessionState(
      status: AuthStatus.authenticated,
      userId: userId,
      activeBusinessId: businessId,
    );
  }

  void setActiveBusiness(String businessId) {
    state = state.copyWith(activeBusinessId: businessId);
  }

  void setUnauthenticated() => state = const SessionState();
}

/// Provider para Notifier en v3
final sessionProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);
