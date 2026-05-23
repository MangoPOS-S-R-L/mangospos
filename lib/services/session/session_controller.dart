import 'dart:async';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:mangopos/core/auth/offline_auth_service.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/core/network/supabase_config.dart';
import 'package:mangopos/core/security/access_control_catalog.dart';
import 'package:mangopos/core/utils/display_name_utils.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/core/utils/web_utils/web_utils.dart';

enum AuthStatus { unauthenticated, authenticated, loading }

enum PosRole { administrador, supervisor, cajero, mesero, cocina, delivery }

enum PinAccessLevel { any, supervisor, admin }

class SessionBusiness {
  final String id;
  final String name;
  final String? companyName;
  final String role;
  final String? status;
  final String? domain;

  const SessionBusiness({
    required this.id,
    required this.name,
    required this.role,
    this.companyName,
    this.status,
    this.domain,
  });

  String get roleLabel {
    switch (role) {
      case 'owner':
      case 'admin':
        return 'Administrador';
      case 'manager':
        return 'Supervisor';
      case 'cashier':
        return 'Cajero';
      case 'waiter':
        return 'Mesero';
      case 'kitchen':
      case 'cook':
      case 'chef':
        return 'Cocina';
      case 'delivery':
        return 'Delivery';
      default:
        return role;
    }
  }
}

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

String? _requestedBusinessIdFromUrl() {
  final direct = Uri.base.queryParameters['business_id'];
  if (direct != null && direct.isNotEmpty) return direct;

  final fragment = Uri.base.fragment;
  if (fragment.isEmpty) return null;
  final queryIndex = fragment.indexOf('?');
  if (queryIndex == -1 || queryIndex == fragment.length - 1) return null;

  final query = fragment.substring(queryIndex + 1);
  return Uri.splitQueryString(query)['business_id'];
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
  final List<SessionBusiness> availableBusinesses;
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
    this.availableBusinesses = const [],
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
    List<SessionBusiness>? availableBusinesses,
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
      availableBusinesses: availableBusinesses ?? this.availableBusinesses,
      permissions: permissions ?? this.permissions,
    );
  }

  bool get isAuthenticated => status == AuthStatus.authenticated;

  bool get isOwner {
    if (activeBusinessId == null) return false;
    for (final b in availableBusinesses) {
      if (b.id == activeBusinessId && b.role == 'owner') return true;
    }
    return false;
  }
}

class SessionController extends Notifier<SessionState> {
  StreamSubscription<AuthState>? _authSub;
  bool _explicitSignOut = false;

  @override
  SessionState build() {
    _authSub?.cancel();
    final auth = Supabase.instance.client.auth;

    _authSub = auth.onAuthStateChange.listen((event) {
      Future.delayed(Duration.zero, () {
        final authEvent = event.event;
        final session = event.session;

        if (authEvent == AuthChangeEvent.signedOut) {
          if (!_explicitSignOut && state.isAuthenticated) {
            // signedOut disparado por fallo de refresh (red, servidor),
            // no por logout del usuario — preservar estado.
            return;
          }
          _explicitSignOut = false;
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
    List<SessionBusiness> availableBusinesses = const [],
    Set<String>? permissions,
  }) {
    final role =
        activeRole ?? (availableRoles.isNotEmpty ? availableRoles.first : null);
    final perms =
        permissions ??
        (role == null ? <String>{} : _rolePermissions[role] ?? <String>{});

    BusinessResolver.setActiveBusinessId(businessId);

    _safeSet(
      SessionState(
        status: AuthStatus.authenticated,
        userId: userId,
        employeeId: employeeId,
        activeBusinessId: businessId,
        activeBusinessName: businessName,
        userName: userName == null
            ? null
            : preferredDisplayName(fullName: userName),
        activeRole: role,
        availableRoles: availableRoles,
        availableBusinesses: availableBusinesses,
        permissions: perms,
      ),
    );

    // Fase 2.6 — auto-sync del roster offline al login y cada hora mientras
    // la app esté abierta + al recuperar conectividad. Idempotente: si ya
    // hay un ciclo corriendo para este business, no duplica. Si el device
    // no fue vinculado, internamente se vuelve no-op.
    if (businessId != null && businessId.isNotEmpty) {
      unawaited(OfflineAuthService().startBackgroundSync(businessId));
    }
  }

  void setActiveBusiness(String businessId) {
    BusinessResolver.setActiveBusinessId(businessId);
    _safeSet(state.copyWith(activeBusinessId: businessId));
  }

  Future<bool> restoreFromSupabaseSession({Session? session}) async {
    final previousState = state;
    final hadAuthenticatedState = previousState.isAuthenticated;
    if (!hadAuthenticatedState) {
      setLoading();
    }
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
      // NO usar user.email como fallback: este nombre puede terminar en
      // tickets impresos / cierres de caja físicos, y exponer email
      // corporativo es info sensible que no corresponde al cliente.
      final fullName =
          profileResp?['full_name'] as String? ??
          user.userMetadata?['full_name'] as String? ??
          'Usuario';

      final memberships = await client
          .from('user_businesses')
          .select('business_id, role, created_at')
          .eq('user_id', user.id)
          .order('created_at', ascending: true);

      if (memberships.isEmpty) {
        setUnauthenticated();
        return false;
      }

      final businessIds = (memberships as List)
          .map((row) => row['business_id']?.toString())
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toList(growable: false);

      final businessesResp = await client
          .from('businesses')
          .select('id, business_name, branch_name, status, domain')
          .inFilter('id', businessIds);

      final businessMap = {
        for (final row in (businessesResp as List).cast<Map<String, dynamic>>())
          row['id'].toString(): row,
      };

      final availableBusinesses = (memberships)
          .map<SessionBusiness>((row) {
            final businessId = row['business_id'].toString();
            final business =
                businessMap[businessId] ?? const <String, dynamic>{};
            final displayName =
                (business['branch_name']?.toString().trim().isNotEmpty == true)
                ? business['branch_name'].toString().trim()
                : (business['business_name']?.toString().trim() ?? 'Negocio');
            return SessionBusiness(
              id: businessId,
              name: displayName,
              companyName: business['business_name']?.toString(),
              role: row['role']?.toString() ?? 'owner',
              status: business['status']?.toString(),
              domain: business['domain']?.toString(),
            );
          })
          .toList(growable: false);

      final requestedBusinessId = _requestedBusinessIdFromUrl();

      String? matchedByDomainId;
      if (kIsWeb) {
        final currentHost = WebUtils.hostname;
        try {
          final matchedDomain = availableBusinesses.firstWhere(
            (b) => b.domain == currentHost,
          );
          matchedByDomainId = matchedDomain.id;
        } catch (_) {
          // No match by domain
        }
      }

      final preferredBusinessId =
          requestedBusinessId != null &&
              businessIds.contains(requestedBusinessId)
          ? requestedBusinessId
          : matchedByDomainId != null && businessIds.contains(matchedByDomainId)
          ? matchedByDomainId
          : state.activeBusinessId != null &&
                businessIds.contains(state.activeBusinessId)
          ? state.activeBusinessId!
          : businessIds.first;

      await _activateBusiness(
        userId: user.id,
        userName: fullName,
        businessId: preferredBusinessId,
        availableBusinesses: availableBusinesses,
      );
      return true;
    } catch (error) {
      if (SupabaseConfig.isAuthRefreshSchemaMismatchError(error)) {
        try {
          await client.auth.signOut(scope: SignOutScope.local);
        } catch (_) {}
        setUnauthenticated();
        return false;
      }

      final sessionStillPresent = client.auth.currentSession != null;
      final shouldPreserveState =
          hadAuthenticatedState ||
          sessionStillPresent ||
          SupabaseConfig.isRecoverableError(error);

      if (shouldPreserveState) {
        _safeSet(previousState);
        return false;
      }

      setUnauthenticated();
      return false;
    }
  }

  Future<void> switchBusiness(String businessId) async {
    final userId = state.userId;
    if (userId == null || userId.isEmpty) return;
    final target = state.availableBusinesses.where((b) => b.id == businessId);
    if (target.isEmpty) return;

    setLoading();
    await _activateBusiness(
      userId: userId,
      userName: state.userName,
      businessId: businessId,
      availableBusinesses: state.availableBusinesses,
    );
  }

  Future<void> _activateBusiness({
    required String userId,
    required String? userName,
    required String businessId,
    required List<SessionBusiness> availableBusinesses,
  }) async {
    final client = Supabase.instance.client;

    final membership = await client
        .from('user_businesses')
        .select('role')
        .eq('user_id', userId)
        .eq('business_id', businessId)
        .maybeSingle();

    final roleStr = membership?['role']?.toString();
    final posRole = _mapRole(roleStr);

    if (roleStr == null || posRole == null) {
      setUnauthenticated();
      return;
    }

    final empResp = await client
        .from('employees')
        .select('id, first_name')
        .eq('user_id', userId)
        .eq('business_id', businessId)
        .maybeSingle();
    final employeeId = empResp?['id'] as String?;
    final employeeFirstName = empResp?['first_name']?.toString();

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
      userId: userId,
      businessId: businessId,
      roleStr: roleStr,
      posRole: posRole,
    );

    setAuthenticated(
      userId,
      employeeId: employeeId,
      businessId: businessId,
      businessName: businessName,
      userName: preferredDisplayName(
        firstName: employeeFirstName,
        fullName: userName,
      ),
      activeRole: posRole,
      availableRoles: [posRole],
      availableBusinesses: availableBusinesses,
      permissions: effectivePermissions,
    );
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
      userName: preferredDisplayName(fullName: found.fullName),
      activeRole: found.roles.first,
      availableRoles: found.roles,
      availableBusinesses: [
        SessionBusiness(
          id: found.businessId,
          name: 'Negocio demo',
          role: 'owner',
          companyName: 'Negocio demo',
        ),
      ],
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

  /// Returns the appropriate home route for the current user's role.
  /// - Owner/Admin/Supervisor → dashboard (full analytics)
  /// - Cashier → cashier (caja)
  /// - Waiter → sales (ventas/mesas)
  /// - Cook → kitchen (KDS)
  /// - Delivery → sales/delivery
  String get homeRoute {
    switch (state.activeRole) {
      case PosRole.administrador:
      case PosRole.supervisor:
        return '/dashboard';
      case PosRole.cajero:
        return '/cashier';
      case PosRole.mesero:
        return '/sales';
      case PosRole.cocina:
        return '/kitchen';
      case PosRole.delivery:
        return '/sales/delivery';
      case null:
        return '/dashboard';
    }
  }

  /// Whether the current user can access the full dashboard.
  /// Controlled by the `dashboard.acceso` permission in the database.
  bool get canAccessDashboard =>
      hasPermission('dashboard.acceso');

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

    // 1) Offline-first: roster cacheado con pin_hash.
    //
    //    Validar contra el cache local antes de pegarle al server tiene dos
    //    beneficios: (a) funciona sin internet (Fase 2 — auth offline nivel
    //    Toast), (b) cuando hay internet pero el server está degradado, no
    //    queda colgado en timeouts. Si el roster está vacío o stale,
    //    seguimos al path online como fallback.
    if (businessId != null && businessId.isNotEmpty) {
      try {
        final matched = await OfflineAuthService().verifyPin(
          businessId: businessId,
          pin: pin,
        );
        if (matched != null) {
          if (level == PinAccessLevel.any) return true;
          final role = _mapRole(matched.role);
          if (role != null && _meetsPinAccess(role, level)) return true;
          // Rol no alcanza el nivel pedido: caemos al fallback en lugar de
          // negar de plano, por si la versión online del rol cambió.
        }
      } catch (e) {
        debugPrint('verifyPin: offline check falló (continuamos online): $e');
      }
    }

    // 2) Online fallback (path histórico). Mientras `pin` plaintext exista
    //    en employees, esto sigue funcionando para apps que aún no hicieron
    //    bindDevice/syncRoster.
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
      } catch (_) {}
    }

    // 3) DEBUG ONLY: PINs hardcodeados de demo (1111/2222/...). Antes
    //    actuaban como fallback en producción, lo que era un agujero de
    //    seguridad (audit offline §H1). Ahora SOLO se activan en builds
    //    de debug para preservar el flujo de desarrollo local.
    if (kDebugMode) {
      for (final user in pinLoginUsers) {
        if (user.pin != pin) continue;
        for (final role in user.roles) {
          if (_meetsPinAccess(role, level)) return true;
        }
      }
    }
    return false;
  }

  Future<bool> verifyCurrentUserPin({required String pin}) async {
    final businessId = state.activeBusinessId;
    final userId = state.userId;

    // 1) Offline-first: validar contra el roster cacheado, restringido al
    //    usuario actualmente logueado. Si el PIN matchea pero pertenece a
    //    OTRO usuario, NO devolvemos true — esa es la diferencia clave con
    //    `verifyPin` (que valida "cualquier autorizado").
    if (businessId != null &&
        businessId.isNotEmpty &&
        userId != null &&
        userId.isNotEmpty) {
      try {
        final matched = await OfflineAuthService().verifyPin(
          businessId: businessId,
          pin: pin,
        );
        if (matched != null && matched.userId == userId) {
          return true;
        }
      } catch (e) {
        debugPrint(
          'verifyCurrentUserPin: offline check falló (continuamos online): $e',
        );
      }
    }

    // 2) Online fallback (path histórico).
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
      } catch (_) {}
    }

    // 3) DEBUG ONLY: PINs demo hardcodeados. Antes era el fallback en
    //    producción (audit §H1 — agujero de seguridad). Ahora solo en
    //    builds de debug.
    if (kDebugMode) {
      final currentUserId = state.userId;
      if (currentUserId != null && currentUserId.isNotEmpty) {
        for (final user in pinLoginUsers) {
          if (user.id == currentUserId && user.pin == pin) {
            return true;
          }
        }
      }
    }

    return false;
  }

  Future<void> setUnauthenticated() async {
    BusinessResolver.resetCache();
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      state = const SessionState();
      completer.complete();
    });
    return completer.future;
  }

  Future<void> signOut() async {
    _explicitSignOut = true;
    try {
      await Supabase.instance.client.auth.signOut();
    } finally {
      _explicitSignOut = false;
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
          // Si user_businesses.role es owner/admin, SIEMPRE wildcard.
          // No tiene sentido restringir a un owner vía overrides parciales:
          // si por error/UI quedan rows incompletas en user_permission_overrides
          // (ej. alguien tildó solo 3 permisos y guardó, borrando el resto),
          // el owner perdía acceso a su propio negocio. La regla de negocio
          // es: si la membresía es owner/admin, manda esa membresía sobre
          // el detalle del RPC.
          final normalizedRole = normalizeBusinessRole(roleStr);
          if (normalizedRole == 'owner' || normalizedRole == 'admin') {
            return {'*', ...granted};
          }
          // Roles no-admin: usar lo que devuelve el RPC tal cual.
          // Si el RPC devolvió algo, esos son sus permisos efectivos.
          return granted;
        }
      }
    } catch (_) {}

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

final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);
