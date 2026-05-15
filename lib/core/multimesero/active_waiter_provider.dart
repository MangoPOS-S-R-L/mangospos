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

  const ActiveWaiter({
    required this.employeeId,
    required this.firstName,
    required this.businessId,
    required this.validatedAt,
    this.lastName,
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
  }) {
    return ActiveWaiter(
      employeeId: employeeId ?? this.employeeId,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      businessId: businessId ?? this.businessId,
      validatedAt: validatedAt ?? this.validatedAt,
    );
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
