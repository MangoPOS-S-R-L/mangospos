// Multimesero — "cada mesero es dueño de su mesa".
//
// Con la sub-opción activa, una mesa abierta solo la abre el mesero que la
// abrió (`opened_by_employee_id`). Estas pruebas fijan quién pasa y quién no;
// el gate en el salón solo resuelve el dueño y aplica esta regla.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/multimesero/active_waiter_provider.dart';
import 'package:mangopos/core/multimesero/table_ownership.dart';

ActiveWaiter _waiter({String employeeId = 'emp-rosa', String? role}) =>
    ActiveWaiter(
      employeeId: employeeId,
      firstName: 'Rosa',
      businessId: 'biz-1',
      validatedAt: DateTime(2026, 9, 16),
      role: role,
    );

TableEntryDecision _decide({
  bool tableOwnerOnly = true,
  String? sessionId = 'ses-1',
  String? openerEmployeeId = 'emp-juan',
  required ActiveWaiter waiter,
}) => decideTableEntry(
  tableOwnerOnly: tableOwnerOnly,
  sessionId: sessionId,
  openerEmployeeId: openerEmployeeId,
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

  group('Cada mesero es dueño de su mesa', () {
    test('el mesero que abrió la mesa entra', () {
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
        TableEntryDecision.ownedByAnotherWaiter,
      );
    });

    test('un mesero sin cuenta de login (rol null) tampoco entra', () {
      expect(
        _decide(waiter: _waiter()),
        TableEntryDecision.ownedByAnotherWaiter,
      );
    });

    test('mesa libre: quien la abre queda como dueño', () {
      expect(_decide(sessionId: null, waiter: _waiter()),
          TableEntryDecision.allowed);
      expect(_decide(sessionId: '', waiter: _waiter()),
          TableEntryDecision.allowed);
    });

    test('mesa sin mesero dueño (la abrió un cajero sin PIN) queda libre', () {
      expect(
        _decide(openerEmployeeId: null, waiter: _waiter()),
        TableEntryDecision.allowed,
      );
    });

    for (final role in ['owner', 'admin', 'manager', 'cashier', 'ADMIN']) {
      test('$role entra a cualquier mesa', () {
        expect(
          _decide(waiter: _waiter(role: role)),
          TableEntryDecision.allowed,
        );
      });
    }
  });
}
