// Multimesero — "cada mesero es dueño de su mesa".
//
// Con la sub-opción activa, una mesa abierta solo la abre quien la abrió: el
// mesero con PIN (`opened_by_employee_id`) o, si se abrió sin PIN, la cuenta
// que la abrió (`opened_by`). Estas pruebas fijan quién pasa y quién no; el
// gate en el salón solo resuelve el dueño y aplica esta regla.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/multimesero/active_waiter_provider.dart';
import 'package:mangopos/core/multimesero/table_ownership.dart';

ActiveWaiter _waiter({
  String employeeId = 'emp-rosa',
  String? userId = 'user-rosa',
  String? role,
}) => ActiveWaiter(
  employeeId: employeeId,
  firstName: 'Rosa',
  businessId: 'biz-1',
  validatedAt: DateTime(2026, 9, 16),
  userId: userId,
  role: role,
);

TableEntryDecision _decide({
  bool tableOwnerOnly = true,
  String? sessionId = 'ses-1',
  String? openerEmployeeId = 'emp-juan',
  String? openerUserId = 'user-tablet',
  bool tableLooksEmpty = false,
  required ActiveWaiter waiter,
}) => decideTableEntry(
  tableOwnerOnly: tableOwnerOnly,
  sessionId: sessionId,
  openerEmployeeId: openerEmployeeId,
  openerUserId: openerUserId,
  tableLooksEmpty: tableLooksEmpty,
  waiter: waiter,
);

void main() {
  group('Opción apagada', () {
    test('cualquier mesero entra a la mesa de otro (comportamiento de hoy)',
        () {
      expect(
        _decide(tableOwnerOnly: false, waiter: _waiter()),
        TableEntryDecision.allowed,
      );
    });
  });

  group('Mesa abierta por un mesero con PIN', () {
    test('el mesero que la abrió entra', () {
      expect(
        _decide(
          openerEmployeeId: 'emp-rosa',
          waiter: _waiter(employeeId: 'emp-rosa'),
        ),
        TableEntryDecision.allowed,
      );
    });

    test('otro mesero NO entra', () {
      expect(
        _decide(waiter: _waiter(role: 'waiter')),
        TableEntryDecision.ownedByAnother,
      );
    });

    test('un mesero sin cuenta de login (rol null) tampoco entra', () {
      expect(
        _decide(waiter: _waiter(userId: null)),
        TableEntryDecision.ownedByAnother,
      );
    });

    test('compartir la cuenta de la tablet no lo hace dueño: manda el PIN', () {
      expect(
        _decide(
          openerUserId: 'user-rosa',
          waiter: _waiter(userId: 'user-rosa'),
        ),
        TableEntryDecision.ownedByAnother,
      );
    });
  });

  group('Mesa abierta sin PIN (admin / cajero)', () {
    test('un mesero NO entra a la mesa del admin', () {
      expect(
        _decide(
          openerEmployeeId: null,
          openerUserId: 'user-admin',
          waiter: _waiter(),
        ),
        TableEntryDecision.ownedByAnother,
      );
    });

    test('la misma cuenta que la abrió sí entra', () {
      expect(
        _decide(
          openerEmployeeId: null,
          openerUserId: 'user-rosa',
          waiter: _waiter(userId: 'user-rosa'),
        ),
        TableEntryDecision.allowed,
      );
    });

    test('sin datos del servidor (sesión que aún no existe allá) entra', () {
      expect(
        _decide(openerEmployeeId: null, openerUserId: null, waiter: _waiter()),
        TableEntryDecision.allowed,
      );
    });
  });

  group('Mesas que se ven libres', () {
    test('sin cuenta: quien la abre queda como dueño', () {
      expect(_decide(sessionId: null, waiter: _waiter()),
          TableEntryDecision.allowed);
      expect(_decide(sessionId: '', waiter: _waiter()),
          TableEntryDecision.allowed);
    });

    test('cuenta huérfana sin órdenes (se pinta libre) no bloquea', () {
      expect(
        _decide(tableLooksEmpty: true, waiter: _waiter()),
        TableEntryDecision.allowed,
      );
    });
  });

  group('Roles que entran a todas', () {
    for (final role in ['owner', 'admin', 'manager', 'cashier', 'ADMIN']) {
      test('$role entra a la mesa de un mesero y a la del admin', () {
        expect(
          _decide(waiter: _waiter(role: role)),
          TableEntryDecision.allowed,
        );
        expect(
          _decide(
            openerEmployeeId: null,
            openerUserId: 'user-admin',
            waiter: _waiter(role: role),
          ),
          TableEntryDecision.allowed,
        );
      });
    }
  });
}
