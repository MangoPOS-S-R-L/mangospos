import 'dart:async';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:mangopos/core/security/access_control_catalog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum AuthStatus { unauthenticated, authenticated, loading }

enum PosRole { administrador, supervisor, cajero, mesero, cocina, delivery }

enum PinAccessLevel { any, supervisor, admin }

extension PosRoleX on PosRole {
  String get label {
    switch (this) {
      case PosRole.administrador:
        return 'Administrador';
      case PosRole.supervisor:
        return 'Supervisor';
      case PosRole.cajero:
        return 'Cajero';
      case PosRole.mesero:
        return 'Mesero';
      case PosRole.cocina:
        return 'Cocina';
      case PosRole.delivery:
        return 'Delivery';
    }
  }
}

class PinLoginUser {
  final String id;
  final String fullName;
  final String businessId;
  final String pin;
  final List<PosRole> roles;

  const PinLoginUser({
    required this.id,
    required this.fullName,
    required this.businessId,
    required this.pin,
    required this.roles,
  });
}

const defaultBusinessId = '4d068df7-a5bf-4f55-bea1-70a84d08d662';

const pinLoginUsers = <PinLoginUser>[
  PinLoginUser(
    id: 'u-admin',
    fullName: 'Admin Demo',
    businessId: defaultBusinessId,
    pin: '1111',
    roles: [PosRole.administrador, PosRole.supervisor, PosRole.cajero],
  ),
  PinLoginUser(
    id: 'u-supervisor',
    fullName: 'Supervisor Demo',
    businessId: defaultBusinessId,
    pin: '2222',
    roles: [PosRole.supervisor, PosRole.cajero, PosRole.mesero],
  ),
  PinLoginUser(
    id: 'u-cajero',
    fullName: 'Cajero Demo',
    businessId: defaultBusinessId,
    pin: '3333',
    roles: [PosRole.cajero],
  ),
  PinLoginUser(
    id: 'u-mesero',
    fullName: 'Mesero Demo',
    businessId: defaultBusinessId,
    pin: '4444',
    roles: [PosRole.mesero],
  ),
  PinLoginUser(
    id: 'u-cocina',
    fullName: 'Cocina Demo',
    businessId: defaultBusinessId,
    pin: '5555',
    roles: [PosRole.cocina],
  ),
  PinLoginUser(
    id: 'u-delivery',
    fullName: 'Delivery Demo',
    businessId: defaultBusinessId,
    pin: '6666',
    roles: [PosRole.delivery],
  ),
];

final _rolePermissions = <PosRole, Set<String>>{
  PosRole.administrador: {'*'},
  PosRole.supervisor: rolePresets['manager']!.permissionCodes,
  PosRole.cajero: rolePresets['cashier']!.permissionCodes,
  PosRole.mesero: rolePresets['waiter']!.permissionCodes,
  PosRole.cocina: rolePresets['cook']!.permissionCodes,
  PosRole.delivery: rolePresets['delivery']!.permissionCodes,
};

bool _hasPermission(Set<String> granted, String permission) {
  if (granted.contains('*')) return true;
  if (granted.contains(permission)) return true;
  final idx = permission.lastIndexOf('.');
  if (idx > 0 && granted.contains('${permission.substring(0, idx)}.*')) {
    return true;
  }
  return false;
}

bool _meetsPinAccess(PosRole role, PinAccessLevel level) {
  switch (level) {
    case PinAccessLevel.any:
      return true;
    case PinAccessLevel.supervisor:
      return role == PosRole.supervisor || role == PosRole.administrador;
    case PinAccessLevel.admin:
      return role == PosRole.administrador;
  }
}

class SessionState {
  final AuthStatus status;
  final String? userId;
  final String? userName;
  final String? employeeId;
  final String? activeBusinessId;
  final String? activeBusinessName;
  final PosRole? activeRole;
  final List<PosRole> availableRoles;
  final Set<String> permissions;

  const SessionState({
    this.status = AuthStatus.unauthenticated,
    this.userId,
    this.userName,
    this.employeeId,
    this.activeBusinessId,
    this.activeBusinessName,
    this.activeRole,
    this.availableRoles = const [],
    this.permissions = const {},
  });

  SessionState copyWith({
    AuthStatus? status,
    String? userId,
    String? userName,
    String? employeeId,
    String? activeBusinessId,
    String? activeBusinessName,
    PosRole? activeRole,
    List<PosRole>? availableRoles,
    Set<String>? permissions,
  }) {
    return SessionState(
      status: status ?? this.status,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      employeeId: employeeId ?? this.employeeId,
      activeBusinessId: activeBusinessId ?? this.activeBusinessId,
      activeBusinessName: activeBusinessName ?? this.activeBusinessName,
      activeRole: activeRole ?? this.activeRole,
      availableRoles: availableRoles ?? this.availableRoles,
      permissions: permissions ?? this.permissions,
    );
  }

  bool get isAuthenticated => status == AuthStatus.authenticated;
}

/// Riverpod 3.0: usar `Notifier` tipado.
class SessionController extends Notifier<SessionState> {
  StreamSubscription<AuthState>? _authSub;

  @override
  SessionState build() {
    _authSub?.cancel();
    final auth = Supabase.instance.client.auth;

    _authSub = auth.onAuthStateChange.listen((event) {
      // Usamos Future.delayed(Duration.zero) para asegurarnos de que la transición
      // de estado ocurra después de que cualquier build actual haya terminado.
      Future.delayed(Duration.zero, () {
        final authEvent = event.event;
        final session = event.session;

        if (authEvent == AuthChangeEvent.signedOut) {
          setUnauthenticated();
          return;
        }

        if (authEvent == AuthChangeEvent.signedIn ||
            authEvent == AuthChangeEvent.tokenRefreshed ||
            authEvent == AuthChangeEvent.userUpdated ||
            authEvent == AuthChangeEvent.initialSession) {
          restoreFromSupabaseSession(session: session);
        }
      });
    });

    // Bootstrapping inicial para reload (web/desktop/mobile).
    Future.delayed(Duration.zero, () => restoreFromSupabaseSession());

    ref.onDispose(() {
      _authSub?.cancel();
      _authSub = null;
    });

    return const SessionState(status: AuthStatus.loading);
  }

  void _safeSet(SessionState next) {
    if (state == next) return;
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) => state = next);
    } else {
      state = next;
    }
  }

  void setLoading() => _safeSet(state.copyWith(status: AuthStatus.loading));

  void setAuthenticated(
    String userId, {
    String? employeeId,
    String? businessId,
    String? businessName,
    String? userName,
    PosRole? activeRole,
    List<PosRole> availableRoles = const [],
    Set<String>? permissions,
  }) {
    final role =
        activeRole ?? (availableRoles.isNotEmpty ? availableRoles.first : null);
    final perms =
        permissions ??
        (role == null ? <String>{} : _rolePermissions[role] ?? <String>{});

    _safeSet(
      SessionState(
        status: AuthStatus.authenticated,
        userId: userId,
        employeeId: employeeId,
        activeBusinessId: businessId,
        activeBusinessName: businessName,
        userName: userName,
        activeRole: role,
        availableRoles: availableRoles,
        permissions: perms,
      ),
    );
  }

  void setActiveBusiness(String businessId) {
    _safeSet(state.copyWith(activeBusinessId: businessId));
  }

  Future<bool> restoreFromSupabaseSession({Session? session}) async {
    setLoading();
    final client = Supabase.instance.client;
    final currentSession = session ?? client.auth.currentSession;
    final user = currentSession?.user;

    if (user == null) {
      setUnauthenticated();
      return false;
    }

    try {
      final profileResp = await client
          .from('profiles')
          .select('full_name')
          .eq('id', user.id)
          .maybeSingle();
      final fullName =
          profileResp?['full_name'] as String? ??
          user.userMetadata?['full_name'] as String? ??
          user.email ??
          'Usuario';

      final userBizResp = await client
          .from('user_businesses')
          .select('business_id, role')
          .eq('user_id', user.id)
          .order('created_at', ascending: true)
          .limit(1)
          .maybeSingle();

      if (userBizResp == null) {
        setUnauthenticated();
        return false;
      }

      final businessId = userBizResp['business_id'] as String?;
      final roleStr = userBizResp['role']?.toString();
      final posRole = _mapRole(roleStr);

      if (businessId == null || businessId.isEmpty || posRole == null) {
        setUnauthenticated();
        return false;
      }

      // Cargar employee_id desde la tabla employees
      final empResp = await client
          .from('employees')
          .select('id')
          .eq('user_id', user.id)
          .eq('business_id', businessId)
          .maybeSingle();
      final employeeId = empResp?['id'] as String?;

      final businessResp = await client
          .from('businesses')
          .select('business_name, branch_name')
          .eq('id', businessId)
          .maybeSingle();
      final businessName =
          (businessResp?['branch_name'] as String?)?.trim().isNotEmpty == true
          ? (businessResp?['branch_name'] as String).trim()
          : (businessResp?['business_name'] as String?)?.trim();

      final effectivePermissions = await _loadEffectivePermissions(
        userId: user.id,
        businessId: businessId,
        roleStr: roleStr,
        posRole: posRole,
      );

      setAuthenticated(
        user.id,
        businessId: businessId,
        businessName: businessName,
        userName: fullName,
        activeRole: posRole,
        availableRoles: [posRole],
        permissions: effectivePermissions,
      );
      return true;
    } catch (_) {
      // Conserva estado previo si ya estaba autenticado.
      if (!state.isAuthenticated) {
        setUnauthenticated();
      }
      return false;
    }
  }

  Future<bool> authenticateWithPin({
    required String pin,
    String? userId,
  }) async {
    PinLoginUser? found;
    if (userId != null && userId.isNotEmpty) {
      for (final candidate in pinLoginUsers) {
        if (candidate.id == userId && candidate.pin == pin) {
          found = candidate;
          break;
        }
      }
    } else {
      for (final candidate in pinLoginUsers) {
        if (candidate.pin == pin) {
          found = candidate;
          break;
        }
      }
    }

    if (found == null) return false;

    setAuthenticated(
      found.id,
      businessId: found.businessId,
      businessName: 'Negocio demo',
      userName: found.fullName,
      activeRole: found.roles.first,
      availableRoles: found.roles,
    );
    return true;
  }

  Future<void> switchRole(PosRole role) async {
    if (!state.availableRoles.contains(role)) return;
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      state = state.copyWith(
        activeRole: role,
        permissions: _rolePermissions[role] ?? <String>{},
      );
      completer.complete();
    });
    return completer.future;
  }

  bool hasPermission(String permission) =>
      _hasPermission(state.permissions, permission);

  bool hasAnyPermission(List<String> permissions) {
    for (final permission in permissions) {
      if (_hasPermission(state.permissions, permission)) return true;
    }
    return false;
  }

  bool hasAllPermissions(List<String> permissions) {
    for (final permission in permissions) {
      if (!_hasPermission(state.permissions, permission)) return false;
    }
    return true;
  }

  Future<bool> verifyPin({
    required String pin,
    PinAccessLevel level = PinAccessLevel.any,
  }) async {
    final businessId = state.activeBusinessId;
    if (businessId != null && businessId.isNotEmpty) {
      final client = Supabase.instance.client;
      try {
        final rows = await client
            .from('employees')
            .select('user_id')
            .eq('business_id', businessId)
            .eq('status', 'active')
            .eq('pin', pin)
            .limit(10);

        final candidates = List<Map<String, dynamic>>.from(rows as List);
        if (candidates.isNotEmpty) {
          if (level == PinAccessLevel.any) {
            return true;
          }

          for (final candidate in candidates) {
            final candidateUserId = candidate['user_id']?.toString();
            if (candidateUserId == null || candidateUserId.isEmpty) {
              continue;
            }

            final membership = await client
                .from('user_businesses')
                .select('role')
                .eq('user_id', candidateUserId)
                .eq('business_id', businessId)
                .maybeSingle();

            final candidateRole = _mapRole(membership?['role']?.toString());
            if (candidateRole != null &&
                _meetsPinAccess(candidateRole, level)) {
              return true;
            }
          }
        }
      } catch (_) {
        // fallback demo below
      }
    }

    for (final user in pinLoginUsers) {
      if (user.pin != pin) continue;
      for (final role in user.roles) {
        if (_meetsPinAccess(role, level)) return true;
      }
    }
    return false;
  }

  Future<bool> verifyCurrentUserPin({required String pin}) async {
    final businessId = state.activeBusinessId;
    final userId = state.userId;

    if (businessId != null &&
        businessId.isNotEmpty &&
        userId != null &&
        userId.isNotEmpty) {
      try {
        final row = await Supabase.instance.client
            .from('employees')
            .select('id')
            .eq('business_id', businessId)
            .eq('user_id', userId)
            .eq('status', 'active')
            .eq('pin', pin)
            .maybeSingle();

        if (row != null) {
          return true;
        }
      } catch (_) {
        // fallback demo below
      }
    }

    final currentUserId = state.userId;
    if (currentUserId != null && currentUserId.isNotEmpty) {
      for (final user in pinLoginUsers) {
        if (user.id == currentUserId && user.pin == pin) {
          return true;
        }
      }
    }

    return false;
  }

  Future<void> setUnauthenticated() async {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      state = const SessionState();
      completer.complete();
    });
    return completer.future;
  }

  Future<void> signOut() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } finally {
      setUnauthenticated();
    }
  }

  Future<Set<String>> _loadEffectivePermissions({
    required String userId,
    required String? businessId,
    required String? roleStr,
    required PosRole? posRole,
  }) async {
    if (businessId == null || businessId.isEmpty) {
      return _fallbackPermissions(roleStr, posRole);
    }

    try {
      final response = await Supabase.instance.client.rpc(
        'fn_user_effective_permissions',
        params: {'p_user_id': userId, 'p_business_id': businessId},
      );

      if (response is List) {
        final granted = response
            .where(
              (row) =>
                  row is Map<String, dynamic> &&
                  row['allowed'] == true &&
                  row['code'] != null,
            )
            .map((row) => (row as Map<String, dynamic>)['code'].toString())
            .where((code) => code.isNotEmpty)
            .toSet();

        if (granted.isNotEmpty) {
          if (normalizeBusinessRole(roleStr) == 'owner' ||
              normalizeBusinessRole(roleStr) == 'admin') {
            return {'*', ...granted};
          }
          return granted;
        }
      }
    } catch (_) {
      // fallback below
    }

    return _fallbackPermissions(roleStr, posRole);
  }

  Set<String> _fallbackPermissions(String? roleStr, PosRole? posRole) {
    final normalizedRole = normalizeBusinessRole(roleStr);
    if (normalizedRole == 'owner' || normalizedRole == 'admin') {
      return {'*'};
    }
    final preset = presetCodesForRole(roleStr);
    if (preset.isNotEmpty) {
      return preset;
    }
    return posRole == null
        ? <String>{}
        : (_rolePermissions[posRole] ?? <String>{});
  }

  PosRole? _mapRole(String? role) {
    switch (role) {
      case 'owner':
      case 'admin':
        return PosRole.administrador;
      case 'manager':
        return PosRole.supervisor;
      case 'cashier':
        return PosRole.cajero;
      case 'waiter':
        return PosRole.mesero;
      case 'kitchen':
      case 'cook':
      case 'chef':
        return PosRole.cocina;
      case 'delivery':
        return PosRole.delivery;
      default:
        return null;
    }
  }
}

/// Provider para Notifier en v3
final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);
