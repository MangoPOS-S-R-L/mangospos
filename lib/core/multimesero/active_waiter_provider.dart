// Modo multimesero: state del PIN validado en este dispositivo.
//
// Concepto:
//   Un POS compartido por varios meseros. Cuando un mesero entra a una mesa
//   y mete su PIN, queda "activo" en el dispositivo. Si vuelve a tocar otra
//   mesa (la suya o la de un compañero), el sistema reusa este state para
//   identificarlo SIN volver a pedirle PIN, mientras se cumplan las reglas
//   (mismo mesero que abrió la mesa = no pide; otro mesero = pide para
//   identificarse).
//
// Persistencia:
//   In-memory. Se pierde al hot restart / cerrar app / logout. Es deliberado:
//   no queremos que el PIN quede pegado entre turnos.
//
// Reset:
//   - Al cerrar sesión Supabase (logout) — manejado en SessionController.
//   - Manualmente al volver a la vista de zona del salón (futuro).

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Snapshot del mesero activo en el dispositivo.
class ActiveWaiter {
  final String employeeId;
  final String firstName;
  final String? lastName;
  final String businessId;
  final DateTime validatedAt;

  /// `user_id` del mesero identificado, cuando tiene cuenta de login.
  /// `fn_verify_employee_pin` ya lo devolvía; antes se descartaba.
  final String? userId;

  /// Permisos efectivos del mesero identificado por PIN.
  ///
  /// `null` = no se pudieron resolver (sin login, sin red, RPC vacío). Es
  /// distinto de `{}` (mesero sin ningún permiso): con `null` los gates
  /// caen a los permisos de la sesión del dispositivo, que es el
  /// comportamiento histórico. Nunca dejamos a un mesero sin operar por un
  /// fallo de lectura.
  final Set<String>? permissions;

  const ActiveWaiter({
    required this.employeeId,
    required this.firstName,
    required this.businessId,
    required this.validatedAt,
    this.lastName,
    this.userId,
    this.permissions,
  });

  /// Nombre legible para mostrar en UI (tarjetas de mesa, etc.).
  String get displayName {
    final last = lastName?.trim() ?? '';
    if (last.isEmpty) return firstName.trim();
    return '${firstName.trim()} $last'.trim();
  }

  ActiveWaiter copyWith({
    String? employeeId,
    String? firstName,
    String? lastName,
    String? businessId,
    DateTime? validatedAt,
    String? userId,
    Set<String>? permissions,
  }) {
    return ActiveWaiter(
      employeeId: employeeId ?? this.employeeId,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      businessId: businessId ?? this.businessId,
      validatedAt: validatedAt ?? this.validatedAt,
      userId: userId ?? this.userId,
      permissions: permissions ?? this.permissions,
    );
  }

  /// Evalúa un permiso contra los del mesero identificado. Devuelve `null`
  /// cuando no hay permisos resueltos — el caller debe caer a la sesión.
  ///
  /// Misma semántica de comodines que `SessionController`: `*` global y
  /// `modulo.*` por prefijo.
  bool? hasPermission(String permission) {
    final granted = permissions;
    if (granted == null) return null;
    if (granted.contains('*')) return true;
    if (granted.contains(permission)) return true;
    final idx = permission.lastIndexOf('.');
    if (idx > 0 && granted.contains('${permission.substring(0, idx)}.*')) {
      return true;
    }
    return false;
  }
}

class ActiveWaiterController extends Notifier<ActiveWaiter?> {
  @override
  ActiveWaiter? build() => null;

  /// Setea el mesero activo. Llamar tras validar PIN exitosamente vía
  /// `fn_verify_employee_pin`.
  void setActive(ActiveWaiter waiter) {
    state = waiter;
  }

  /// Limpia el state. Útil al hacer logout o si el admin quiere forzar
  /// reidentificación del mesero (ej. cambio de turno).
  void clear() {
    state = null;
  }

  /// True si el `employeeId` pasado coincide con el mesero actualmente
  /// activo. Usado por el flujo de tap-en-mesa para decidir si pedir PIN
  /// o pasar directo.
  bool matches(String? employeeId) {
    if (employeeId == null || employeeId.isEmpty) return false;
    return state?.employeeId == employeeId;
  }
}

final activeWaiterProvider =
    NotifierProvider<ActiveWaiterController, ActiveWaiter?>(
  ActiveWaiterController.new,
);
