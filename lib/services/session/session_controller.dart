import 'dart:async';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:mangopos/core/auth/offline_auth_service.dart';
import 'package:mangopos/core/multimesero/active_waiter_provider.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
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

    _clearActiveWaiterIfForeign(businessId);
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
      // Prewarm del cache de impresoras por área. Sin esto, si el cajero
      // pierde la red antes de imprimir a un área que nunca usó (típico:
      // "bebidas" en negocios donde solo se había impreso a "cocina"
      // hasta ahora), sendLocalOrderToKitchen falla con "No hay
      // impresoras cacheadas para X". Fire-and-forget: si la red falla,
      // las áreas que sí se pudieron cachear quedan; el resto reintenta
      // al siguiente login.
      unawaited(
        PrintingService(Supabase.instance.client)
            .prewarmPrinterCache(businessId: businessId),
      );
    }
  }

  void setActiveBusiness(String businessId) {
    _clearActiveWaiterIfForeign(businessId);
    BusinessResolver.setActiveBusinessId(businessId);
    _safeSet(state.copyWith(activeBusinessId: businessId));
  }

  /// Descarta el PIN multimesero cacheado si pertenece a otro negocio.
  /// Un waiter validado en el negocio A no debe quedar como identidad
  /// activa al cambiar al negocio B.
  void _clearActiveWaiterIfForeign(String? businessId) {
    final waiter = ref.read(activeWaiterProvider);
    if (waiter == null) return;
    if (businessId == null ||
        businessId.isEmpty ||
        waiter.businessId != businessId) {
      ref.read(activeWaiterProvider.notifier).clear();
    }
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

      final membershipRows = await client
          .from('user_businesses')
          .select('business_id, role, created_at, shared_across_branches')
          .eq('user_id', user.id)
          .order('created_at', ascending: true);

      // Propietario multi-sucursal: además de sus filas en `user_businesses`,
      // incluimos TODAS las sucursales que posee (`businesses.owner_id`), aunque
      // no tenga una fila explícita — p. ej. una sucursal creada por un empleado
      // suyo queda con owner_id = él. Así el dueño ve y puede cambiar a todas
      // sus sucursales. El acceso a los DATOS lo respalda el RLS
      // (`current_user_business_ids()` incluye las de owner_id).
      final ownedRows = await client
          .from('businesses')
          .select('id, business_name, branch_name, status, domain')
          .eq('owner_id', user.id);

      if ((membershipRows as List).isEmpty && (ownedRows as List).isEmpty) {
        setUnauthenticated();
        return false;
      }

      final membershipBusinessIds = membershipRows
          .map((row) => row['business_id']?.toString())
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toList(growable: false);

      // Info de negocios para las filas de user_businesses (los `ownedRows` ya
      // traen su propia info).
      final businessesResp = membershipBusinessIds.isEmpty
          ? const <Map<String, dynamic>>[]
          : await client
                .from('businesses')
                .select('id, business_name, branch_name, status, domain, owner_id')
                .inFilter('id', membershipBusinessIds);

      final businessMap = {
        for (final row in (businessesResp as List).cast<Map<String, dynamic>>())
          row['id'].toString(): row,
      };

      String displayNameOf(Map<String, dynamic> b) =>
          (b['branch_name']?.toString().trim().isNotEmpty == true)
          ? b['branch_name'].toString().trim()
          : (b['business_name']?.toString().trim() ?? 'Negocio');

      // Dedupe por id preservando orden: primero las filas de user_businesses
      // (respetan su role), luego las poseídas sin fila (role 'owner').
      final availableById = <String, SessionBusiness>{};
      for (final row in membershipRows) {
        final businessId = row['business_id'].toString();
        final business = businessMap[businessId] ?? const <String, dynamic>{};
        availableById[businessId] = SessionBusiness(
          id: businessId,
          name: displayNameOf(business),
          companyName: business['business_name']?.toString(),
          role: row['role']?.toString() ?? 'owner',
          status: business['status']?.toString(),
          domain: business['domain']?.toString(),
        );
      }
      for (final row in (ownedRows).cast<Map<String, dynamic>>()) {
        final businessId = row['id'].toString();
        if (availableById.containsKey(businessId)) continue;
        availableById[businessId] = SessionBusiness(
          id: businessId,
          name: displayNameOf(row),
          companyName: row['business_name']?.toString(),
          role: 'owner',
          status: row['status']?.toString(),
          domain: row['domain']?.toString(),
        );
      }

      // --- Usuario compartido entre sucursales (shared_across_branches) ---
      // Para cada fila marcada, el usuario accede a TODAS las hermanas (mismo
      // `owner_id`) del grupo, con el rol de esa fila. Menor rank = más
      // privilegio; si varias filas apuntan al mismo grupo, gana la de mayor
      // privilegio. El acceso a los DATOS lo respalda el RLS
      // (`current_user_business_ids()` incluye las hermanas del grupo).
      int roleRank(String? r) {
        const order = [
          'owner',
          'admin',
          'manager',
          'cashier',
          'waiter',
          'cook',
          'chef',
          'delivery',
        ];
        final i = order.indexOf(r ?? '');
        return i < 0 ? order.length : i;
      }

      final sharedOwnerRole = <String, String>{}; // owner_id -> mejor role
      for (final row in membershipRows) {
        if (row['shared_across_branches'] != true) continue;
        final home = businessMap[row['business_id']?.toString()];
        final ownerId = home?['owner_id']?.toString();
        if (ownerId == null || ownerId.isEmpty) continue;
        final role = row['role']?.toString() ?? 'owner';
        final existing = sharedOwnerRole[ownerId];
        if (existing == null || roleRank(role) < roleRank(existing)) {
          sharedOwnerRole[ownerId] = role;
        }
      }

      if (sharedOwnerRole.isNotEmpty) {
        final siblingRows = await client
            .from('businesses')
            .select('id, business_name, branch_name, status, domain, owner_id')
            .inFilter('owner_id', sharedOwnerRole.keys.toList());
        for (final row in (siblingRows as List).cast<Map<String, dynamic>>()) {
          final businessId = row['id'].toString();
          if (availableById.containsKey(businessId)) continue;
          final ownerId = row['owner_id']?.toString();
          availableById[businessId] = SessionBusiness(
            id: businessId,
            name: displayNameOf(row),
            companyName: row['business_name']?.toString(),
            role: sharedOwnerRole[ownerId] ?? 'cashier',
            status: row['status']?.toString(),
            domain: row['domain']?.toString(),
          );
        }
      }

      final availableBusinesses = availableById.values.toList(growable: false);
      final businessIds = availableBusinesses
          .map((b) => b.id)
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

    var roleStr = membership?['role']?.toString();

    // Propietario sin fila en `user_businesses` de ESTA sucursal: si es el
    // `owner_id` del negocio, se le trata como 'owner' (acceso a todas sus
    // sucursales). Evita que cambiar a una sucursal propia sin fila explícita
    // lo desloguee; los permisos caen en wildcard vía _fallbackPermissions y
    // el acceso a datos lo garantiza el RLS por owner_id.
    String? targetOwnerId;
    if (roleStr == null) {
      final target = await client
          .from('businesses')
          .select('id, owner_id')
          .eq('id', businessId)
          .maybeSingle();
      targetOwnerId = target?['owner_id']?.toString();
      if (target != null && targetOwnerId == userId) roleStr = 'owner';
    }

    // Usuario compartido entre sucursales: sin fila directa ni owner_id, pero
    // con una fila marcada `shared_across_branches` en otra sucursal del mismo
    // grupo (mismo `owner_id`). Hereda el rol de esa fila. El RLS respalda el
    // acceso a datos vía la rama de usuario compartido.
    if (roleStr == null &&
        targetOwnerId != null &&
        targetOwnerId.isNotEmpty) {
      final shared = await client
          .from('user_businesses')
          .select('role, businesses!inner(owner_id)')
          .eq('user_id', userId)
          .eq('shared_across_branches', true)
          .eq('businesses.owner_id', targetOwnerId)
          .limit(1)
          .maybeSingle();
      if (shared != null) roleStr = shared['role']?.toString() ?? 'cashier';
    }

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

    // Normaliza el PIN tipeado: trim previene falsos negativos cuando el
    // cajero pega un PIN con espacios o cuando el `pin` quedó guardado en
    // employees con padding accidental (caso típico con teclados numéricos
    // de tablet). El server (fn_verify_employee_pin / trigger
    // fn_employees_hash_pin) también trimea, pero hacerlo aquí garantiza
    // que los 3 caminos (offline bcrypt, RPC, SELECT directo) reciben el
    // mismo input limpio.
    final normalizedPin = pin.trim();
    if (normalizedPin.isEmpty) return false;

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
          pin: normalizedPin,
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

    // 2) Online: RPC fn_verify_employee_pin (trimea internamente, corre
    //    SECURITY DEFINER → bypassea RLS, valida que el caller pertenezca
    //    al business, y devuelve también el `role` del empleado en
    //    user_businesses).
    //
    //    El `role` viene del server porque el RLS user_businesses_select_own
    //    impide que el cliente lo lea directamente para users distintos
    //    al logueado (un cajero no puede ver la fila de Ricardo en
    //    user_businesses). Sin esto, el role lookup separado devolvía
    //    null silenciosamente → "PIN inválido" aunque el PIN fuera
    //    correcto. Ver migración 20260528_0006.
    if (businessId != null && businessId.isNotEmpty) {
      final client = Supabase.instance.client;
      try {
        final result = await client.rpc(
          'fn_verify_employee_pin',
          params: <String, dynamic>{
            'p_business_id': businessId,
            'p_pin': normalizedPin,
          },
        );

        if (result != null) {
          if (level == PinAccessLevel.any) return true;

          final resultMap = result is Map
              ? Map<String, dynamic>.from(result)
              : null;
          final candidateRole = _mapRole(resultMap?['role']?.toString());
          if (candidateRole != null && _meetsPinAccess(candidateRole, level)) {
            return true;
          }
        }
      } catch (e) {
        // Antes: catch silencioso → cajero veía "PIN inválido" sin pista de
        // por qué. Ahora logueamos y caemos al SELECT directo como
        // compatibilidad para self-hosted que aún no tengan la RPC
        // (migración 20260516_0001_multimesero_setup.sql).
        debugPrint('verifyPin: RPC fn_verify_employee_pin falló: $e');

        try {
          final rows = await client
              .from('employees')
              .select('user_id')
              .eq('business_id', businessId)
              .eq('status', 'active')
              .eq('pin', normalizedPin)
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

              // NOTA: este lookup falla por RLS si el caller no es el
              // mismo user_id; queda como mejor esfuerzo para servers
              // viejos sin la migración 20260528_0006.
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
        } catch (e2) {
          debugPrint('verifyPin: SELECT directo fallback también falló: $e2');
        }
      }
    }

    // 3) DEBUG ONLY: PINs hardcodeados de demo (1111/2222/...). Antes
    //    actuaban como fallback en producción, lo que era un agujero de
    //    seguridad (audit offline §H1). Ahora SOLO se activan en builds
    //    de debug para preservar el flujo de desarrollo local.
    if (kDebugMode) {
      for (final user in pinLoginUsers) {
        if (user.pin != normalizedPin) continue;
        for (final role in user.roles) {
          if (_meetsPinAccess(role, level)) return true;
        }
      }
    }
    return false;
  }

  /// Como [verifyPin] pero devuelve el `user_id` del empleado que autorizó
  /// (para persistirlo en columnas de auditoría tipo `approved_by`).
  /// Devuelve null si el PIN es inválido o el rol no alcanza el nivel.
  ///
  /// Mismo orden offline-first que [verifyPin]: roster cacheado primero,
  /// RPC `fn_verify_employee_pin` como fallback online. No incluye el
  /// SELECT directo legacy ni los PINs de demo porque este método existe
  /// para auditoría y ahí un user_id real es obligatorio.
  Future<String?> verifyPinApprover({
    required String pin,
    PinAccessLevel level = PinAccessLevel.supervisor,
  }) async {
    final businessId = state.activeBusinessId;
    final normalizedPin = pin.trim();
    if (normalizedPin.isEmpty) return null;
    if (businessId == null || businessId.isEmpty) return null;

    try {
      final matched = await OfflineAuthService().verifyPin(
        businessId: businessId,
        pin: normalizedPin,
      );
      if (matched != null) {
        final role = _mapRole(matched.role);
        if (role != null &&
            _meetsPinAccess(role, level) &&
            matched.userId.isNotEmpty) {
          return matched.userId;
        }
        // Rol insuficiente en cache: caemos al path online por si cambió.
      }
    } catch (e) {
      debugPrint('verifyPinApprover: offline check falló: $e');
    }

    try {
      final result = await Supabase.instance.client.rpc(
        'fn_verify_employee_pin',
        params: <String, dynamic>{
          'p_business_id': businessId,
          'p_pin': normalizedPin,
        },
      );
      if (result is Map) {
        final resultMap = Map<String, dynamic>.from(result);
        final role = _mapRole(resultMap['role']?.toString());
        final userId = resultMap['user_id']?.toString();
        if (role != null &&
            userId != null &&
            userId.isNotEmpty &&
            _meetsPinAccess(role, level)) {
          return userId;
        }
      }
    } catch (e) {
      debugPrint('verifyPinApprover: RPC fn_verify_employee_pin falló: $e');
    }
    return null;
  }

  Future<bool> verifyCurrentUserPin({required String pin}) async {
    final businessId = state.activeBusinessId;
    final userId = state.userId;

    // Mismo trim defensivo que verifyPin: el trigger fn_employees_hash_pin
    // trimea el PIN antes de hashear, así que el bcrypt offline contra
    // pin_hash espera input trimeado. Y el SELECT directo `.eq('pin', ...)`
    // es exacto, falla con padding.
    final normalizedPin = pin.trim();
    if (normalizedPin.isEmpty) return false;

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
          pin: normalizedPin,
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

    // 2) Online fallback (path histórico). Acá no hay problema de RLS
    //    porque la query es sobre el employee del propio user logueado
    //    (employees by business → el caller siempre puede ver su propia
    //    fila como mínimo).
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
            .eq('pin', normalizedPin)
            .maybeSingle();

        if (row != null) {
          return true;
        }
      } catch (e) {
        debugPrint('verifyCurrentUserPin: online check falló: $e');
      }
    }

    // 3) DEBUG ONLY: PINs demo hardcodeados. Antes era el fallback en
    //    producción (audit §H1 — agujero de seguridad). Ahora solo en
    //    builds de debug.
    if (kDebugMode) {
      final currentUserId = state.userId;
      if (currentUserId != null && currentUserId.isNotEmpty) {
        for (final user in pinLoginUsers) {
          if (user.id == currentUserId && user.pin == normalizedPin) {
            return true;
          }
        }
      }
    }

    return false;
  }

  Future<void> setUnauthenticated() async {
    // El PIN multimesero es identidad del usuario/turno, no del device:
    // si sobrevive al logout, el próximo usuario abre mesas atribuidas
    // al mesero anterior (precuenta/factura salen con otro nombre).
    ref.read(activeWaiterProvider.notifier).clear();
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
    // Capturamos el negocio activo ANTES de resetear el state: tras
    // setUnauthenticated() activeBusinessId queda null y no sabríamos qué
    // limpiar.
    final businessId = state.activeBusinessId;
    try {
      await Supabase.instance.client.auth.signOut();
    } finally {
      _explicitSignOut = false;
      // Limpieza al cerrar sesión. IMPORTANTE: NO descartamos operaciones
      // offline SIN SINCRONIZAR — deben quedarse para subir en el próximo
      // login (mismo u otro cajero); perderlas sería perder ventas/inventario.
      // Con preservePending solo podamos lo ya `completed`; la cola pendiente,
      // snapshots y mappings se conservan. Best-effort: nunca bloquea el logout.
      if (businessId != null && businessId.isNotEmpty) {
        try {
          await OfflinePosService()
              .clearOfflineBusinessData(businessId, preservePending: true);
        } catch (e) {
          debugPrint('[session] limpieza offline en signOut falló: $e');
        }
      }
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
