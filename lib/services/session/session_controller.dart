import 'package:flutter_riverpod/flutter_riverpod.dart';

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

const _rolePermissions = <PosRole, Set<String>>{
  PosRole.administrador: {'*'},
  PosRole.supervisor: {
    'ventas.mesas.acceso',
    'ventas.mesas.abrir',
    'ventas.orden.enviar_cocina',
    'ventas.orden.ver_total',
    'ventas.cuenta.split_manual',
    'ventas.cuenta.split_equiv',
    'ventas_rapida.acceso',
    'ventas_rapida.crear_orden',
    'ventas_rapida.enviar_cocina',
    'delivery.crear_orden',
    'pagos.acceso',
    'pagos.cobrar_efectivo',
    'pagos.cobrar_tarjeta',
    'pagos.cobrar_transferencia',
    'caja.apertura',
    'caja.cierre',
    'kds.acceso',
    'reportes.ventas',
    'inventario.acceso',
    'settings.usuarios.acceso',
  },
  PosRole.cajero: {
    'ventas.mesas.acceso',
    'ventas.orden.ver_total',
    'ventas_rapida.acceso',
    'ventas_rapida.crear_orden',
    'pagos.acceso',
    'pagos.cobrar_efectivo',
    'pagos.cobrar_tarjeta',
    'pagos.cobrar_transferencia',
    'caja.apertura',
    'caja.cierre',
  },
  PosRole.mesero: {
    'ventas.mesas.acceso',
    'ventas.mesas.abrir',
    'ventas.orden.agregar_item',
    'ventas.orden.editar_item',
    'ventas.orden.eliminar_item',
    'ventas.orden.enviar_cocina',
    'ventas.orden.ver_total',
    'ventas.cuenta.split_manual',
    'ventas.cuenta.split_equiv',
  },
  PosRole.cocina: {'kds.acceso'},
  PosRole.delivery: {'delivery.crear_orden', 'ventas_rapida.acceso'},
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
  final String? activeBusinessId;
  final PosRole? activeRole;
  final List<PosRole> availableRoles;
  final Set<String> permissions;

  const SessionState({
    this.status = AuthStatus.unauthenticated,
    this.userId,
    this.userName,
    this.activeBusinessId,
    this.activeRole,
    this.availableRoles = const [],
    this.permissions = const {},
  });

  SessionState copyWith({
    AuthStatus? status,
    String? userId,
    String? userName,
    String? activeBusinessId,
    PosRole? activeRole,
    List<PosRole>? availableRoles,
    Set<String>? permissions,
  }) {
    return SessionState(
      status: status ?? this.status,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      activeBusinessId: activeBusinessId ?? this.activeBusinessId,
      activeRole: activeRole ?? this.activeRole,
      availableRoles: availableRoles ?? this.availableRoles,
      permissions: permissions ?? this.permissions,
    );
  }

  bool get isAuthenticated => status == AuthStatus.authenticated;
}

/// Riverpod 3.0 → usar Notifier<T>
class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() => const SessionState();

  void setLoading() => state = state.copyWith(status: AuthStatus.loading);

  void setAuthenticated(
    String userId, {
    String? businessId,
    String? userName,
    PosRole? activeRole,
    List<PosRole> availableRoles = const [],
  }) {
    final role =
        activeRole ?? (availableRoles.isNotEmpty ? availableRoles.first : null);
    final perms = role == null
        ? <String>{}
        : _rolePermissions[role] ?? <String>{};
    state = SessionState(
      status: AuthStatus.authenticated,
      userId: userId,
      activeBusinessId: businessId,
      userName: userName,
      activeRole: role,
      availableRoles: availableRoles,
      permissions: perms,
    );
  }

  void setActiveBusiness(String businessId) {
    state = state.copyWith(activeBusinessId: businessId);
  }

  bool authenticateWithPin({required String pin, String? userId}) {
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
      userName: found.fullName,
      activeRole: found.roles.first,
      availableRoles: found.roles,
    );
    return true;
  }

  void switchRole(PosRole role) {
    if (!state.availableRoles.contains(role)) return;
    state = state.copyWith(
      activeRole: role,
      permissions: _rolePermissions[role] ?? <String>{},
    );
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

  bool verifyPin({
    required String pin,
    PinAccessLevel level = PinAccessLevel.any,
  }) {
    for (final user in pinLoginUsers) {
      if (user.pin != pin) continue;
      for (final role in user.roles) {
        if (_meetsPinAccess(role, level)) return true;
      }
    }
    return false;
  }

  void setUnauthenticated() => state = const SessionState();
}

/// Provider para Notifier en v3
final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);
