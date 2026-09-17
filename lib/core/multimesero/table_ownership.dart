// Multimesero — "cada mesero es dueño de su mesa".
//
// Sub-opción del modo multimesero (`multimesero_table_owner_only`). Con el
// modo normal cualquier mesero entra a cualquier mesa identificándose con su
// PIN. Con esta opción, una mesa abierta solo la puede abrir el mesero que la
// abrió por primera vez (`table_sessions.opened_by_employee_id`).
//
// Siguen entrando a todas:
//   - dueño / administrador / supervisor / cajero (por PIN o por el rol del
//     dispositivo, que ni pasa por el gate de multimesero);
//   - cualquiera, si la mesa no tiene un mesero dueño identificado (la abrió
//     un cajero o admin sin PIN).
//
// Regla pura, sin I/O: la vista resuelve el dueño y decide aquí.

import 'active_waiter_provider.dart';

enum TableEntryDecision {
  allowed,

  /// La mesa es de otro mesero. Se puede destrabar con PIN de supervisor.
  ownedByAnotherWaiter,
}

TableEntryDecision decideTableEntry({
  required bool tableOwnerOnly,
  required String? sessionId,
  required String? openerEmployeeId,
  required ActiveWaiter waiter,
}) {
  if (!tableOwnerOnly) return TableEntryDecision.allowed;
  // Mesa libre: quien la abre queda como dueño.
  if (sessionId == null || sessionId.isEmpty) return TableEntryDecision.allowed;
  // Sin dueño identificado no hay a quién proteger.
  if (openerEmployeeId == null || openerEmployeeId.isEmpty) {
    return TableEntryDecision.allowed;
  }
  if (openerEmployeeId == waiter.employeeId) return TableEntryDecision.allowed;
  if (waiter.canEnterAnyTable) return TableEntryDecision.allowed;
  return TableEntryDecision.ownedByAnotherWaiter;
}
