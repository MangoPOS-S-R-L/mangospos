// Multimesero — "cada mesero es dueño de su mesa".
//
// Sub-opción del modo multimesero (`multimesero_table_owner_only`). Con el
// modo normal cualquier mesero entra a cualquier mesa identificándose con su
// PIN. Con esta opción, una mesa abierta solo la abre quien la abrió:
//
//   - Si la abrió un mesero con PIN → ese mesero
//     (`table_sessions.opened_by_employee_id`).
//   - Si la abrió alguien sin PIN (admin, cajero) → esa cuenta
//     (`table_sessions.opened_by`). Ningún mesero entra, salvo que sea esa
//     misma cuenta de usuario.
//
// Siguen entrando a todas: dueño / administrador / supervisor / cajero (por
// PIN o por el rol del dispositivo, que ni pasa por el gate de multimesero).
// Un mesero bloqueado puede entrar con PIN de supervisor.
//
// Regla pura, sin I/O: la vista resuelve el dueño y decide aquí.

import 'active_waiter_provider.dart';

enum TableEntryDecision {
  allowed,

  /// La mesa es de otra persona. Se puede destrabar con PIN de supervisor.
  ownedByAnother,
}

TableEntryDecision decideTableEntry({
  required bool tableOwnerOnly,
  required String? sessionId,
  required String? openerEmployeeId,
  required String? openerUserId,
  required ActiveWaiter waiter,
  bool tableLooksEmpty = false,
}) {
  if (!tableOwnerOnly) return TableEntryDecision.allowed;
  // Mesa libre: quien la abre queda como dueño.
  if (sessionId == null || sessionId.isEmpty) return TableEntryDecision.allowed;
  // Cuenta abierta sin órdenes: el salón la pinta LIBRE (quedó huérfana y el
  // barrido la cierra). Bloquear una mesa que se ve disponible no tiene
  // sentido para quien la toca.
  if (tableLooksEmpty) return TableEntryDecision.allowed;
  if (waiter.canEnterAnyTable) return TableEntryDecision.allowed;

  final openerEmployee = openerEmployeeId?.trim() ?? '';
  if (openerEmployee.isNotEmpty) {
    return openerEmployee == waiter.employeeId
        ? TableEntryDecision.allowed
        : TableEntryDecision.ownedByAnother;
  }

  // Abierta sin PIN de mesero: la dueña es la cuenta que la abrió.
  final openerUser = openerUserId?.trim() ?? '';
  // Sin dato del servidor (sesión que aún no existe allá) no hay a quién
  // proteger.
  if (openerUser.isEmpty) return TableEntryDecision.allowed;
  final waiterUser = waiter.userId?.trim() ?? '';
  return waiterUser.isNotEmpty && waiterUser == openerUser
      ? TableEntryDecision.allowed
      : TableEntryDecision.ownedByAnother;
}
